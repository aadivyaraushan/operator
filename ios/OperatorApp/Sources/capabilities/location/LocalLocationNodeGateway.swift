import Foundation
import OperatorCore
import OSLog

actor LocalLocationNodeGateway {
    private let url: URL
    private let vault: GatewayInstallationVault
    private let appVersion: String
    private let platform: String
    private let handler: any GatewayNodeCommandHandler
    private let agentTools: @Sendable () -> [GatewayNodeAgentToolDescriptor]
    private let policySetup: NativeNodePolicySetup
    private let reconnectDelay: @Sendable () async -> Void
    private let logger = Logger(subsystem: "app.operator.ios", category: "location-node-runtime")
    private var connection: OpenClawNodeConnection?
    private var runTask: Task<Void, Never>?

    init(
        url: URL,
        vault: GatewayInstallationVault,
        appVersion: String,
        platform: String,
        handler: any GatewayNodeCommandHandler,
        agentTools: @escaping @Sendable () -> [GatewayNodeAgentToolDescriptor] = { GatewayNodeAgentTools.descriptors },
        reconnectDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        })
    {
        self.agentTools = agentTools
        self.url = url
        self.vault = vault
        self.appVersion = appVersion
        self.platform = platform
        self.handler = handler
        self.policySetup = NativeNodePolicySetup(connectionFactory: {
            let credentials = try await vault.loadOrCreate()
            return OpenClawGatewayConnection(
                transport: URLSessionGatewayTransport(url: url, timeout: 30),
                token: credentials.gatewayToken,
                identity: credentials.identity,
                metadata: .init(appVersion: appVersion, platform: platform, instanceID: credentials.instanceID))
        })
        self.reconnectDelay = reconnectDelay
    }

    func start() {
        guard self.runTask == nil else { return }
        self.logger.info("[location-node] starting foreground node route")
        self.runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// The owner changed a grant: offer the model the new tool set now rather
    /// than on the next reconnect.
    func republishAgentTools() async {
        await self.connection?.republishAgentTools()
    }

    func stop() async {
        self.runTask?.cancel()
        self.runTask = nil
        if let connection = self.connection {
            await connection.disconnect()
        }
        self.connection = nil
        self.logger.info("[location-node] stopped foreground node route")
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                guard try await self.policySetup.prepare() else {
                    await self.reconnectDelay()
                    continue
                }
                try Task.checkCancellation()
                let credentials = try await self.vault.loadOrCreate()
                let connection = OpenClawNodeConnection(
                    transport: URLSessionGatewayTransport(url: self.url, timeout: 30),
                    token: credentials.gatewayToken,
                    identity: credentials.identity,
                    appVersion: self.appVersion,
                    platform: self.platform,
                    approveOwnDeviceRole: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.approveOwnDeviceRole(credentials: credentials)
                    },
                    agentTools: self.agentTools)
                self.connection = connection
                try await connection.connect()
                if try await self.prepareNativeNode(credentials: credentials) {
                    // Approval creates a new pairing generation. Reconnect before
                    // accepting commands so this socket belongs to that generation.
                    self.logger.info("[location-node] own command surface approved; reconnecting")
                    await connection.disconnect()
                    self.connection = nil
                    continue
                }
                self.logger.info("[location-node] own command surface verified")
                while !Task.isCancelled {
                    try await connection.receiveAndHandleNext(using: self.handler)
                }
            } catch {
                if Task.isCancelled { break }
                self.logger.error(
                    "[location-node] route interrupted error=\(String(describing: error), privacy: .public)")
            }
            if let connection = self.connection {
                await connection.disconnect()
            }
            self.connection = nil
            guard !Task.isCancelled else { break }
            await self.reconnectDelay()
        }
    }

    private func prepareNativeNode(credentials: GatewayInstallationCredentials) async throws -> Bool {
        let control = OpenClawGatewayConnection(
            transport: URLSessionGatewayTransport(url: self.url, timeout: 30),
            token: credentials.gatewayToken,
            identity: credentials.identity,
            metadata: .init(
                appVersion: self.appVersion,
                platform: self.platform,
                instanceID: credentials.instanceID))
        do {
            try await control.connect()
            let approved = try await control.prepareNativeNode()
            await control.disconnect()
            return approved
        } catch {
            await control.disconnect()
            throw error
        }
    }

    private func approveOwnDeviceRole(credentials: GatewayInstallationCredentials) async throws {
        let control = OpenClawGatewayConnection(
            transport: URLSessionGatewayTransport(url: self.url, timeout: 30),
            token: credentials.gatewayToken, identity: credentials.identity,
            metadata: .init(appVersion: self.appVersion, platform: self.platform, instanceID: credentials.instanceID))
        do {
            try await control.connect()
            try await control.approveOwnNativeDeviceRole()
            await control.disconnect()
        } catch {
            await control.disconnect()
            throw error
        }
    }
}
