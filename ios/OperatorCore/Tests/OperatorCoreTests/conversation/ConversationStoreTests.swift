import Foundation
import XCTest
@testable import OperatorCore

final class ConversationStoreTests: XCTestCase {
    func testSnapshotFromBeforeWeatherCardsStillDecodesWithoutChangingDraftOrOutbox() throws {
        let legacy = Data(#"{"messages":[{"id":"11111111-2222-3333-4444-555555555555","role":"user","text":"queued request","createdAt":0,"delivery":"waiting"}],"draft":"keep this draft","outbox":[{"id":"11111111-2222-3333-4444-555555555555","messageID":"11111111-2222-3333-4444-555555555555","text":"queued request","idempotencyKey":"keep-this-send-id","state":"waiting"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: legacy)
        XCTAssertNil(snapshot.messages.first?.attachment)
        XCTAssertEqual(snapshot.messages.first?.text, "queued request")
        XCTAssertEqual(snapshot.draft, "keep this draft")
        XCTAssertEqual(snapshot.outbox.first?.idempotencyKey, "keep-this-send-id")
        XCTAssertEqual(snapshot.outbox.first?.state, .waiting)
    }

    func testWeatherCardPersistsAsAnIndependentSystemMessageAcrossRelaunch() async throws {
        let fileURL = temporaryFileURL()
        let store = ConversationStore(fileURL: fileURL)
        let before = try await store.stageUserMessage(text: "queued request")
        _ = try await store.updateDraft("keep this draft")
        let card = WeatherCard(
            temperatureCelsius: 18.5, apparentCelsius: 17, condition: "Partly Cloudy",
            humidity: 0.62, windKilometresPerHour: 11.2, highCelsius: 21, lowCelsius: 12,
            attribution: .init(
                legalPageURL: URL(string: "https://weather.example/legal")!,
                combinedMarkLightURL: URL(string: "https://weather.example/light")!,
                combinedMarkDarkURL: URL(string: "https://weather.example/dark")!))

        _ = try await ConversationStore(fileURL: fileURL).appendWeatherCard(card)
        let restored = try await ConversationStore(fileURL: fileURL).load()

        XCTAssertEqual(restored.messages.last?.role, .system)
        XCTAssertEqual(restored.messages.last?.attachment, .weather(card))
        XCTAssertEqual(restored.messages.last?.text, "Weather forecast")
        XCTAssertEqual(restored.messages.first, before.messages.first)
        XCTAssertEqual(restored.outbox, before.outbox)
        XCTAssertEqual(restored.draft, "keep this draft")
        XCTAssertEqual(restored.messages.count, 2)
    }
    func testStageUserMessagePersistsMessageDraftAndStableOutboxIdentity() async throws {
        let fileURL = temporaryFileURL()
        let store = ConversationStore(fileURL: fileURL)

        try await store.updateDraft("book a table")
        let staged = try await store.stageUserMessage(text: "book a table")

        XCTAssertEqual(staged.messages.map(\.text), ["book a table"])
        XCTAssertEqual(staged.messages.first?.delivery, .waiting)
        XCTAssertEqual(staged.draft, "")
        XCTAssertEqual(staged.outbox.count, 1)
        XCTAssertEqual(staged.outbox.first?.messageID, staged.messages.first?.id)
        XCTAssertEqual(staged.outbox.first?.idempotencyKey, staged.messages.first?.id.uuidString.lowercased())

        let relaunched = ConversationStore(fileURL: fileURL)
        let restored = try await relaunched.load()
        XCTAssertEqual(restored, staged)
    }

    func testSendingEntryReturnsToWaitingAfterRelaunchWithoutChangingItsKey() async throws {
        let fileURL = temporaryFileURL()
        let store = ConversationStore(fileURL: fileURL)
        let staged = try await store.stageUserMessage(text: "send once")
        let entry = try XCTUnwrap(staged.outbox.first)

        _ = try await store.markSending(entryID: entry.id)

        let relaunched = ConversationStore(fileURL: fileURL)
        let restored = try await relaunched.load()
        XCTAssertEqual(restored.outbox.first?.state, .waiting)
        XCTAssertEqual(restored.outbox.first?.idempotencyKey, entry.idempotencyKey)
        XCTAssertEqual(restored.messages.first?.delivery, .waiting)
    }

    func testActiveConnectionFailureReturnsEntryToWaitingWithoutChangingItsKey() async throws {
        let store = ConversationStore(fileURL: temporaryFileURL())
        let staged = try await store.stageUserMessage(text: "retry after reconnect")
        let entry = try XCTUnwrap(staged.outbox.first)
        _ = try await store.markSending(entryID: entry.id)

        let waiting = try await store.markWaiting(entryID: entry.id)

        XCTAssertEqual(waiting.outbox.first?.state, .waiting)
        XCTAssertEqual(waiting.outbox.first?.idempotencyKey, entry.idempotencyKey)
        XCTAssertEqual(waiting.messages.first?.delivery, .waiting)
    }

    func testAcceptedSendLeavesReadableMessageAndRemovesOutboxEntry() async throws {
        let store = ConversationStore(fileURL: temporaryFileURL())
        let staged = try await store.stageUserMessage(text: "hello")
        let entry = try XCTUnwrap(staged.outbox.first)

        let accepted = try await store.markAccepted(entryID: entry.id)

        XCTAssertTrue(accepted.outbox.isEmpty)
        XCTAssertEqual(accepted.messages.first?.delivery, .accepted)
    }

    func testCallerSuppliedMessageIdentitySurvivesPersistenceAndRetry() async throws {
        let messageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let fileURL = temporaryFileURL()
        let store = ConversationStore(fileURL: fileURL)

        let staged = try await store.stageUserMessage(
            id: messageID,
            text: "keep this identity")
        let restored = try await ConversationStore(fileURL: fileURL).load()

        XCTAssertEqual(staged.messages.first?.id, messageID)
        XCTAssertEqual(staged.outbox.first?.id, messageID)
        XCTAssertEqual(restored.outbox.first?.idempotencyKey, messageID.uuidString.lowercased())
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("conversation.json", isDirectory: false)
    }
}
