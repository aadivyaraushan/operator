import Foundation
import OperatorCore

protocol ChatPersistence: Sendable {
    func restore() async throws -> ConversationSnapshot
    func saveDraft(_ draft: String) async throws -> ConversationSnapshot
    func stage(id: UUID, text: String, now: Date) async throws -> ConversationSnapshot
    func markSending(id: UUID) async throws -> ConversationSnapshot
    func markAccepted(id: UUID) async throws -> ConversationSnapshot
    func markWaiting(id: UUID) async throws -> ConversationSnapshot
    func appendAssistant(_ text: String) async throws -> ConversationSnapshot
    func appendWeatherCard(_ card: WeatherCard) async throws -> ConversationSnapshot
}

enum ChatDeliveryUpdate: Equatable, Sendable {
    case accepted
    case working
    case stream(String)
    case reply(String)
    case failed(String)
    case stopped
}

enum ChatApprovalUpdate: Sendable {
    case replay(GatewayApprovalReplay)
    case event(GatewaySessionApprovalEvent)
    case canonical(GatewayApprovalSnapshot)
    case unsafe(String)
}

protocol ChatGateway: Sendable {
    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    func stop() async
    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    func resolveApproval(
        id: String,
        kind: GatewayApprovalKind,
        decision: GatewayApprovalDecision) async throws -> GatewayApprovalSnapshot
}

extension ChatGateway {
    func stop() async {}

    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws {}

    func resolveApproval(
        id: String,
        kind: GatewayApprovalKind,
        decision: GatewayApprovalDecision) async throws -> GatewayApprovalSnapshot
    {
        throw ChatGatewayError.gateway("Approvals are not available until Operator reconnects.")
    }
}

enum ChatGatewayError: Error, Sendable {
    case offline
    case gateway(String)
}
