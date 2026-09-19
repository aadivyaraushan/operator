import Foundation
import OperatorCore

actor CoreChatPersistence: ChatPersistence {
    private let store: ConversationStore

    init(fileURL: URL) {
        self.store = ConversationStore(fileURL: fileURL)
    }

    func restore() async throws -> ConversationSnapshot {
        try await self.store.load()
    }

    func saveDraft(_ draft: String) async throws -> ConversationSnapshot {
        try await self.store.updateDraft(draft)
    }

    func stage(id: UUID, text: String, now: Date) async throws -> ConversationSnapshot {
        try await self.store.stageUserMessage(id: id, text: text, now: now)
    }

    func markSending(id: UUID) async throws -> ConversationSnapshot {
        try await self.store.markSending(entryID: id)
    }

    func markAccepted(id: UUID) async throws -> ConversationSnapshot {
        try await self.store.markAccepted(entryID: id)
    }

    func markWaiting(id: UUID) async throws -> ConversationSnapshot {
        try await self.store.markWaiting(entryID: id)
    }

    func appendAssistant(_ text: String) async throws -> ConversationSnapshot {
        try await self.store.appendAssistant(text: text)
    }

    func appendWeatherCard(_ card: WeatherCard) async throws -> ConversationSnapshot {
        try await self.store.appendWeatherCard(card)
    }
}
