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
    /// A tool the agent started or finished while working on this message.
    case activity(GatewayRunActivity)
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

/// A question the model asked and is waiting on (`ask_user`), as the chat
/// learns of it: the gateway's pending list on each foreground connection,
/// then one event per request and per resolution during a run.
enum ChatQuestionUpdate: Sendable {
    case replay([GatewayQuestionRecord])
    case requested(GatewayQuestionRecord)
    case resolved(GatewayQuestionResolvedEvent)
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
    /// Starts question updates on the current foreground connection and
    /// replays what the gateway still holds. Called right after
    /// `activateApprovalUpdates`, on the connection it opened.
    func activateQuestionUpdates(
        _ update: @escaping @Sendable (ChatQuestionUpdate) async -> Void) async throws
    func answerQuestion(id: String, answers: GatewayQuestionAnswers) async throws
    func cancelQuestion(id: String) async throws
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

    func activateQuestionUpdates(
        _ update: @escaping @Sendable (ChatQuestionUpdate) async -> Void) async throws {}

    func answerQuestion(id: String, answers: GatewayQuestionAnswers) async throws {
        throw ChatGatewayError.gateway("Questions cannot be answered until Operator reconnects.")
    }

    func cancelQuestion(id: String) async throws {
        throw ChatGatewayError.gateway("Questions cannot be answered until Operator reconnects.")
    }
}

enum ChatGatewayError: Error, Sendable {
    case offline
    case gateway(String)
}
