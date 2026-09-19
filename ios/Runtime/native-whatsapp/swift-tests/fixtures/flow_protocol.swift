import OperatorCore

protocol WhatsAppLinkFlowGateway: Sendable {
    func start(phone: String) async throws -> WhatsAppLinkOperation
    func status(operationID: String) async throws -> WhatsAppLinkStatus
    func cancel(operationID: String) async throws -> WhatsAppLinkOperation
}
