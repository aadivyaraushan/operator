import Foundation

public actor WhatsAppLinkGatewayClient {
    public typealias ConnectionFactory = @Sendable () async throws -> OpenClawGatewayConnection

    private let connectionFactory: ConnectionFactory

    public init(connectionFactory: @escaping ConnectionFactory) {
        self.connectionFactory = connectionFactory
    }

    public func start(phone: String) async throws -> WhatsAppLinkOperation {
        try await withFreshConnection { connection in
            try await connection.request(
                method: "operator.whatsappLink.start",
                params: WhatsAppLinkStartParams(phone: phone))
        }
    }

    public func status(operationID: String) async throws -> WhatsAppLinkStatus {
        try await withFreshConnection { connection in
            try await connection.request(
                method: "operator.whatsappLink.status",
                params: WhatsAppLinkOperationParams(operationId: operationID))
        }
    }

    public func cancel(operationID: String) async throws -> WhatsAppLinkOperation {
        try await withFreshConnection { connection in
            try await connection.request(
                method: "operator.whatsappLink.cancel",
                params: WhatsAppLinkOperationParams(operationId: operationID))
        }
    }

    private func withFreshConnection<Result: Sendable>(
        _ operation: @Sendable (OpenClawGatewayConnection) async throws -> Result) async throws -> Result
    {
        let connection = try await self.connectionFactory()
        do {
            try await connection.connect()
            let result = try await operation(connection)
            await connection.disconnect()
            return result
        } catch {
            await connection.disconnect()
            throw error
        }
    }
}
