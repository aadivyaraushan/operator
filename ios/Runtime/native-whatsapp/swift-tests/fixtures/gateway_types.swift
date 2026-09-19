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
