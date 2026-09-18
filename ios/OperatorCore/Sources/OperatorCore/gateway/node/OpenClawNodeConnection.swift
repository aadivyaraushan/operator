import Foundation
import OSLog

public actor OpenClawNodeConnection {
    public private(set) var isConnected = false

    private let transport: any GatewayTransport
    private let token: String
    private let identity: GatewayDeviceIdentity
    private let appVersion: String
    private let platform: String
    private let requestID: @Sendable () -> String
    private let pairingRetryDelay: @Sendable () async -> Void
    private let approveOwnDeviceRole: @Sendable () async throws -> Void
    /// The tools to offer the model, read fresh on every publish so a grant
    /// the owner changes mid-session takes effect on the next republish.
    private let agentTools: @Sendable () -> [GatewayNodeAgentToolDescriptor]
    private let handshakeTimeoutMilliseconds: Int
    private let logger = Logger(subsystem: "app.operator.ios", category: "location-node")
    private var bufferedFrames: [Data] = []

    public init(
        transport: any GatewayTransport,
        token: String,
        identity: GatewayDeviceIdentity,
        appVersion: String,
        platform: String = "ios",
        requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        pairingRetryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(250))
        },
        approveOwnDeviceRole: @escaping @Sendable () async throws -> Void = {},
        agentTools: @escaping @Sendable () -> [GatewayNodeAgentToolDescriptor] = { GatewayNodeAgentTools.descriptors },
        handshakeTimeoutMilliseconds: Int = GatewayDeadline.defaultMilliseconds)
    {
        self.agentTools = agentTools
        self.handshakeTimeoutMilliseconds = handshakeTimeoutMilliseconds
        self.transport = transport
        self.token = token
        self.identity = identity
        self.appVersion = appVersion
        self.platform = platform
        self.requestID = requestID
        self.pairingRetryDelay = pairingRetryDelay
        self.approveOwnDeviceRole = approveOwnDeviceRole
    }

    public func connect() async throws {
        guard !self.isConnected else { return }
        var pairingRetriesRemaining = 40
        while true {
            self.logger.info("[location-node] opening local node websocket")
            do {
                try await GatewayDeadline.handshake(milliseconds: self.handshakeTimeoutMilliseconds) {
                    try await self.connectOnce()
                }
                return
            } catch {
                self.isConnected = false
                await self.transport.close()
                let gatewayError = (error as? OpenClawGatewayError)
                    ?? OpenClawGatewayError.transport(String(describing: error))
                if case let .rejected(code, _) = gatewayError,
                   code == "NOT_PAIRED",
                   pairingRetriesRemaining > 0
                {
                    pairingRetriesRemaining -= 1
                    try Task.checkCancellation()
                    try await self.approveOwnDeviceRole()
                    self.logger.info(
                        "[location-node] pairing pending retriesRemaining=\(pairingRetriesRemaining)")
                    await self.pairingRetryDelay()
                    continue
                }
                self.logger.error(
                    "[location-node] connect failed error=\(String(describing: gatewayError), privacy: .public)")
                throw gatewayError
            }
        }
    }

    public func receiveAndHandleNext(using handler: any GatewayNodeCommandHandler) async throws {
        guard self.isConnected else { throw OpenClawGatewayError.notConnected }
        while true {
            let data = try await self.nextFrame()
            let header = try JSONDecoder().decode(NodeFrameHeader.self, from: data)
            guard header.type == "event", header.event == "node.invoke.request" else {
                continue
            }
            let frame = try JSONDecoder().decode(
                GatewayEventFrame<GatewayNodeInvocation>.self,
                from: data)
            let invocation = frame.payload
            guard invocation.nodeId == self.identity.deviceID else {
                self.logger.error("[location-node] rejected invocation for another node")
                throw OpenClawGatewayError.invalidFrame
            }
            let result: GatewayNodeCommandResult
            if !GatewayNativeNodeSurface.commands.contains(invocation.command) {
                result = .failure(
                    code: "UNSUPPORTED_COMMAND",
                    message: "This iPhone node does not support \(invocation.command)")
            } else if !Self.isValidParamsJSON(invocation.paramsJSON) {
                result = .failure(
                    code: "INVALID_REQUEST",
                    message: "Node command parameters were not valid JSON")
            } else {
                self.logger.info(
                    "[location-node] handling command=\(invocation.command, privacy: .public) id=\(invocation.id, privacy: .public)")
                result = await handler.handleNodeCommand(
                    invocation.command,
                    paramsJSON: invocation.paramsJSON,
                    timeoutMilliseconds: invocation.timeoutMilliseconds)
            }
            try await self.sendResult(result, for: invocation)
            return
        }
    }

    public func disconnect() async {
        self.isConnected = false
        self.bufferedFrames.removeAll(keepingCapacity: false)
        await self.transport.close()
        self.logger.info("[location-node] disconnected")
    }

    private func connectOnce() async throws {
        try await self.transport.open()
        let challengeData = try await self.transport.receive()
        let challengeFrame = try JSONDecoder().decode(
            GatewayEventFrame<GatewayConnectChallenge>.self,
            from: challengeData)
        guard challengeFrame.type == "event",
              challengeFrame.event == "connect.challenge",
              !challengeFrame.payload.nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              challengeFrame.payload.issuedAtMilliseconds >= 0
        else {
            throw OpenClawGatewayError.invalidChallenge
        }

        let connectID = self.requestID()
        let request = try GatewayRequestFactory.nodeConnect(
            requestID: connectID,
            token: self.token,
            identity: self.identity,
            challenge: challengeFrame.payload,
            appVersion: self.appVersion,
            platform: self.platform)
        try await self.transport.send(try JSONEncoder().encode(request))

        while true {
            let responseData = try await self.transport.receive()
            let header = try JSONDecoder().decode(NodeFrameHeader.self, from: responseData)
            guard header.type == "res", header.id == connectID else { continue }
            let response = try JSONDecoder().decode(GatewayResponseFrame.self, from: responseData)
            guard response.ok else {
                throw OpenClawGatewayError.rejected(
                    code: response.error?.code ?? "CONNECT_REJECTED",
                    message: response.error?.message ?? "Gateway rejected the node connection")
            }
            self.isConnected = true
            self.logger.info("[location-node] connected protocol=3-4 commands=\(GatewayNativeNodeSurface.commands.joined(separator: ","), privacy: .public)")
            await self.publishAgentTools()
            return
        }
    }

    /// Publishing is best-effort: a node that cannot advertise tools is still
    /// a working node for anything the person drives directly, so a failure
    /// here must not tear down a connection that is otherwise fine.
    private func publishAgentTools() async {
        let id = self.requestID()
        let tools = self.agentTools()
        do {
            let request = GatewayRequestFactory.nodePluginToolsUpdate(requestID: id, tools: tools)
            try await self.transport.send(try JSONEncoder().encode(request))
        } catch {
            self.logger.error("[location-node] could not publish agent tools")
            return
        }
        self.logger.info(
            "[location-node] published agent tools count=\(tools.count, privacy: .public) commands=\(tools.map(\.command).joined(separator: ","), privacy: .public)")
    }

    /// Re-offer the model the current tool set on a live connection. Called
    /// when the owner changes a grant; a no-op when not connected, because
    /// the next connect publishes anyway.
    public func republishAgentTools() async {
        guard self.isConnected else { return }
        await self.publishAgentTools()
    }

    private func sendResult(
        _ result: GatewayNodeCommandResult,
        for invocation: GatewayNodeInvocation) async throws
    {
        let id = self.requestID()
        let request = GatewayRequestFactory.nodeInvokeResult(
            requestID: id,
            invocation: invocation,
            result: result)
        try await self.transport.send(try JSONEncoder().encode(request))
        self.logger.info("[location-node] sent result id=\(invocation.id, privacy: .public)")

        while true {
            let data = try await self.transport.receive()
            let header = try JSONDecoder().decode(NodeFrameHeader.self, from: data)
            guard header.type == "res", header.id == id else {
                self.bufferedFrames.append(data)
                continue
            }
            let response = try JSONDecoder().decode(
                GatewayRPCResponseFrame<GatewayNodeResultAcknowledgement>.self,
                from: data)
            guard response.ok else {
                throw OpenClawGatewayError.rejected(
                    code: response.error?.code ?? "RESULT_REJECTED",
                    message: response.error?.message ?? "Gateway rejected the node result")
            }
            return
        }
    }

    private func nextFrame() async throws -> Data {
        if !self.bufferedFrames.isEmpty {
            return self.bufferedFrames.removeFirst()
        }
        return try await self.transport.receive()
    }

    private static func isValidParamsJSON(_ paramsJSON: String?) -> Bool {
        guard let paramsJSON else { return true }
        guard let data = paramsJSON.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
    }
}

private struct NodeFrameHeader: Decodable {
    let type: String
    let id: String?
    let event: String?
}
