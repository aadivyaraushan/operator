import Foundation

public struct GatewayNodeConnectParams: Encodable, Sendable {
    public struct Client: Encodable, Sendable {
        public let id: String
        public let displayName: String
        public let version: String
        public let platform: String
        public let deviceFamily: String
        public let mode: String
        public let instanceId: String
    }

    public struct Auth: Encodable, Sendable {
        public let token: String
    }

    public let minProtocol: Int
    public let maxProtocol: Int
    public let client: Client
    public let role: String
    public let scopes: [String]
    public let caps: [String]
    public let commands: [String]
    public let auth: Auth
    public let device: GatewaySignedDevice
}

public struct GatewayNodePluginToolsUpdateParams: Encodable, Sendable {
    public let tools: [GatewayNodeAgentToolDescriptor]
}

public struct GatewayNodeInvocation: Decodable, Equatable, Sendable {
    public let id: String
    public let nodeId: String
    public let command: String
    public let paramsJSON: String?
    public let timeoutMilliseconds: Int?
    public let idempotencyKey: String
    public let sessionKey: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeId
        case command
        case paramsJSON
        case timeoutMilliseconds = "timeoutMs"
        case idempotencyKey
        case sessionKey
    }
}

public struct GatewayNodeResultError: Encodable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct GatewayNodeInvokeResultParams: Encodable, Equatable, Sendable {
    public let id: String
    public let nodeId: String
    public let ok: Bool
    public let payloadJSON: String?
    public let error: GatewayNodeResultError?
}

public struct GatewayNodeResultAcknowledgement: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let ignored: Bool?
}

public enum GatewayNodeCommandResult: Equatable, Sendable {
    case success(payloadJSON: String)
    case failure(code: String, message: String)
}

public protocol GatewayNodeCommandHandler: Sendable {
    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
}

public extension GatewayRequestFactory {
    static func nodeConnect(
        requestID: String,
        token: String,
        identity: GatewayDeviceIdentity,
        challenge: GatewayConnectChallenge,
        appVersion: String,
        platform: String) throws -> GatewayRequest<GatewayNodeConnectParams>
    {
        let scopes: [String] = []
        let proof = try GatewayDeviceProof.makeV3(
            identity: identity,
            challenge: challenge,
            token: token,
            clientID: "node-host",
            clientMode: "node",
            role: "node",
            scopes: scopes,
            platform: platform,
            deviceFamily: "iPhone")
        return GatewayRequest(
            id: requestID,
            method: "connect",
            params: GatewayNodeConnectParams(
                minProtocol: 3,
                maxProtocol: 4,
                client: .init(
                    id: "node-host",
                    displayName: "Operator iPhone",
                    version: appVersion,
                    platform: platform,
                    deviceFamily: "iPhone",
                    mode: "node",
                    instanceId: identity.deviceID),
                role: "node",
                scopes: scopes,
                caps: GatewayNativeNodeSurface.capabilities,
                commands: GatewayNativeNodeSurface.commands,
                auth: .init(token: token),
                device: proof.device))
    }

    /// Publishes the descriptors that make this node's read commands callable
    /// by the agent. Without this the gateway has the commands but the model
    /// has no tools, so it never reaches for them.
    static func nodePluginToolsUpdate(
        requestID: String,
        tools: [GatewayNodeAgentToolDescriptor] = GatewayNodeAgentTools.descriptors) -> GatewayRequest<GatewayNodePluginToolsUpdateParams>
    {
        GatewayRequest(
            id: requestID,
            method: "node.pluginTools.update",
            params: GatewayNodePluginToolsUpdateParams(tools: tools))
    }

    static func nodeInvokeResult(
        requestID: String,
        invocation: GatewayNodeInvocation,
        result: GatewayNodeCommandResult) -> GatewayRequest<GatewayNodeInvokeResultParams>
    {
        let params: GatewayNodeInvokeResultParams
        switch result {
        case let .success(payloadJSON):
            params = GatewayNodeInvokeResultParams(
                id: invocation.id,
                nodeId: invocation.nodeId,
                ok: true,
                payloadJSON: payloadJSON,
                error: nil)
        case let .failure(code, message):
            params = GatewayNodeInvokeResultParams(
                id: invocation.id,
                nodeId: invocation.nodeId,
                ok: false,
                payloadJSON: nil,
                error: GatewayNodeResultError(code: code, message: message))
        }
        return GatewayRequest(id: requestID, method: "node.invoke.result", params: params)
    }
}
