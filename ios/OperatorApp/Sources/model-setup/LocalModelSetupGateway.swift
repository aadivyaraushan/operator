import Foundation
import OperatorCore
import OSLog

actor LocalModelSetupGateway: ModelSetupGateway {
    // The pinned Gateway gives its setup inference probe 90 seconds. Keep enough
    // time after a gateway-owned restart for the WebSocket handshake as well.
    static let serverSetupProbeTimeout: Duration = .seconds(90)
    static let gatewayReconnectTimeout: Duration = .seconds(60)
    static let productionVerificationTimeout = serverSetupProbeTimeout + gatewayReconnectTimeout

    private struct EmptyParams: Encodable, Sendable {}

    private struct ConfigGetResponse: Decodable, Sendable {
        let valid: Bool
        let config: Config
    }

    private struct Config: Decodable, Sendable {
        let agents: Agents?
    }

    private struct Agents: Decodable, Sendable {
        let defaults: Agent?
        private let roster: Roster?

        private enum CodingKeys: String, CodingKey {
            case defaults
            case entries
            case list
        }

        private enum Roster: Sendable {
            case entries([String: Agent]?)
            case list([ListedAgent])
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.defaults = try values.decodeIfPresent(Agent.self, forKey: .defaults)
            if values.contains(.entries) {
                if try values.decodeNil(forKey: .entries) {
                    self.roster = .entries(nil)
                } else {
                    self.roster = .entries(try values.decode([String: Agent].self, forKey: .entries))
                }
            } else if values.contains(.list) {
                self.roster = .list(try values.decode([ListedAgent].self, forKey: .list))
            } else {
                self.roster = nil
            }
        }

        func model(for agentID: String) -> ModelReference? {
            switch self.roster {
            case let .entries(entries):
                return entries?[agentID]?.model
            case let .list(entries):
                return entries.first {
                    $0.id?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == agentID.lowercased()
                }?.model
            case nil:
                return nil
            }
        }
    }

    private struct Agent: Decodable, Sendable {
        let model: ModelReference?
    }

    private struct ListedAgent: Decodable, Sendable {
        let id: String?
        let model: ModelReference?
    }

    private enum ModelReference: Decodable, Sendable {
        case string(String)
        case object(primary: String?)

        private enum CodingKeys: String, CodingKey { case primary }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                self = .string(value)
                return
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self = .object(primary: try values.decodeIfPresent(String.self, forKey: .primary))
        }

        var trimmedPrimary: String? {
            let value: String?
            switch self {
            case let .string(model): value = model
            case let .object(primary): value = primary
            }
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private enum ConfigurationError: Error { case invalidConfig }

    private struct AuthStartParams: Encodable, Sendable {
        let sessionId: String
        let authChoice = "openai-device-code"
    }

    private struct WizardAnswer: Encodable, Sendable {
        let stepId: String
    }

    private struct WizardNextParams: Encodable, Sendable {
        let sessionId: String
        let answer: WizardAnswer?
    }

    private struct WizardSessionParams: Encodable, Sendable {
        let sessionId: String
    }

    private struct WizardStatus: Decodable, Sendable {
        let status: String
        let error: String?
    }

    private struct Verification: Decodable, Sendable {
        let ok: Bool
        let modelRef: String?
        let status: String?
    }

    private enum VerificationError: Error {
        case missingBootIdentity
        case wrongModel
        case verificationFailed
        case timedOut
    }

    private let connectionFactory: @Sendable () async throws -> OpenClawGatewayConnection
    let verificationTimeout: Duration
    private let logger = Logger(subsystem: "app.operator.ios", category: "model-setup")
    private var connection: OpenClawGatewayConnection?
    private var activationBootID: String?

    init(url: URL, vault: GatewayInstallationVault, appVersion: String, platform: String) {
        self.verificationTimeout = Self.productionVerificationTimeout
        self.connectionFactory = {
            let credentials = try await vault.loadOrCreate()
            return OpenClawGatewayConnection(
                transport: URLSessionGatewayTransport(
                    url: url, timeout: TimeInterval(Self.gatewayReconnectTimeout.components.seconds)),
                token: credentials.gatewayToken,
                identity: credentials.identity,
                metadata: .init(appVersion: appVersion, platform: platform, instanceID: credentials.instanceID))
        }
    }

    init(
        connectionFactory: @escaping @Sendable () async throws -> OpenClawGatewayConnection,
        verificationTimeout: Duration = LocalModelSetupGateway.productionVerificationTimeout)
    {
        self.connectionFactory = connectionFactory
        self.verificationTimeout = verificationTimeout
    }

    func configuration() async throws -> ModelSetupConfiguration {
        let response: ConfigGetResponse
        do {
            response = try await self.readConfiguration()
        } catch {
            self.logger.error("[setup] configuration read failed category=request")
            throw error
        }
        guard response.valid else {
            self.logger.error("[setup] configuration read failed category=invalid")
            throw ConfigurationError.invalidConfig
        }
        let model = response.config.agents?.model(for: OpenClawGatewayConnection.defaultAgentID)?.trimmedPrimary
            ?? response.config.agents?.defaults?.model?.trimmedPrimary
        let hasConfiguredModel = model != nil
        self.logger.info("[setup] configuration read modelConfigured=\(hasConfiguredModel)")
        return ModelSetupConfiguration(hasConfiguredModel: hasConfiguredModel)
    }

    private func readConfiguration() async throws -> ConfigGetResponse {
        let connection = try await self.connectionFactory()
        do {
            try await connection.connect()
            let response: ConfigGetResponse = try await connection.request(
                method: "config.get", params: EmptyParams())
            await connection.disconnect()
            return response
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    func startDeviceCode(sessionID: String) async throws -> ModelSetupWizardResult {
        let connection = try await self.readyConnection()
        self.activationBootID = await connection.currentGatewayBootID
        return try await self.perform(
            method: "openclaw.setup.auth.start",
            params: AuthStartParams(sessionId: sessionID))
    }

    func next(sessionID: String, answeringStepID: String?) async throws -> ModelSetupWizardResult {
        try await self.perform(
            method: "wizard.next",
            params: WizardNextParams(
                sessionId: sessionID,
                answer: answeringStepID.map(WizardAnswer.init(stepId:))))
    }

    func cancel(sessionID: String) async {
        do {
            let _: WizardStatus = try await self.perform(
                method: "wizard.cancel",
                params: WizardSessionParams(sessionId: sessionID))
            self.logger.info("[setup] cancelled provider authorization")
        } catch {
            self.logger.error("[setup] provider authorization cancel failed")
        }
    }

    func disconnect() async {
        await self.connection?.disconnect()
        self.connection = nil
    }

    func verifyActivation(_ activation: ModelSetupActivation) async throws {
        let restartRequired = activation.gatewayRestartRequired == true
        guard !restartRequired || self.activationBootID != nil else {
            self.logger.error("[setup] restart verification missing activation boot identity")
            await self.disconnect()
            throw VerificationError.missingBootIdentity
        }
        self.logger.info("[setup] verifying activation restartRequired=\(restartRequired)")
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.waitForVerifiedActivation(activation) }
                    group.addTask {
                        try await Task.sleep(for: self.verificationTimeout)
                        // Closing the socket also releases an outstanding receive.
                        await self.disconnect()
                        throw VerificationError.timedOut
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } onCancel: {
                Task { await self.disconnect() }
            }
            self.logger.info("[setup] activated model verified on the current gateway")
        } catch {
            await self.disconnect()
            self.logger.error("[setup] activation verification failed error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func waitForVerifiedActivation(_ activation: ModelSetupActivation) async throws {
        let previousBootID = activation.gatewayRestartRequired == true ? self.activationBootID : nil
        var retryDelay: Duration = .milliseconds(250)
        if previousBootID != nil { await self.disconnect() }
        while true {
            try Task.checkCancellation()
            do {
                let connection = try await self.readyConnection()
                if let previousBootID {
                    guard let bootID = await connection.currentGatewayBootID else {
                        throw VerificationError.missingBootIdentity
                    }
                    if bootID == previousBootID {
                        self.logger.debug("[setup] waiting for gateway-owned restart")
                        await self.disconnect()
                        try await Task.sleep(for: retryDelay)
                        retryDelay = min(retryDelay * 2, .seconds(2))
                        continue
                    }
                }
                let verification: Verification = try await self.perform(
                    method: "openclaw.setup.verify", params: EmptyParams())
                if verification.ok {
                    guard verification.modelRef?.trimmingCharacters(in: .whitespacesAndNewlines)
                        == activation.modelRef.trimmingCharacters(in: .whitespacesAndNewlines)
                    else { throw VerificationError.wrongModel }
                    return
                }
                guard verification.status == "unavailable" else { throw VerificationError.verificationFailed }
                self.logger.debug("[setup] saved configuration is not active yet")
            } catch let error as OpenClawGatewayError {
                switch error {
                case .transport, .notConnected, .handshakeTimedOut: break
                default: throw error
                }
                self.logger.debug("[setup] gateway transport unavailable during verification")
            } catch is URLError {
                self.logger.debug("[setup] gateway socket unavailable during verification")
            }
            await self.disconnect()
            try await Task.sleep(for: retryDelay)
            retryDelay = min(retryDelay * 2, .seconds(2))
        }
    }

    private func perform<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params) async throws -> Result
    {
        let connection = try await self.readyConnection()
        do {
            return try await connection.request(method: method, params: params)
        } catch {
            await connection.disconnect()
            self.connection = nil
            throw error
        }
    }

    private func readyConnection() async throws -> OpenClawGatewayConnection {
        if let connection, await connection.isConnected {
            return connection
        }
        let connection = try await self.connectionFactory()
        try Task.checkCancellation()
        // Publish before connect so timeout/cancellation can close a pending handshake.
        self.connection = connection
        try await connection.connect()
        return connection
    }
}
