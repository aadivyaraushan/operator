import Foundation
import MessageUI
import XCTest
@testable import OperatorApp

final class IncomingMessageStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.directory)
        super.tearDown()
    }

    func testRecordsNewestFirstAndAnotherInstanceReadsTheSameFile() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = IncomingMessageStore(supportDirectory: self.directory, now: { clock })
        XCTAssertNotNil(store.record(sender: "Mom", text: "dinner at 7?"))
        clock = clock.addingTimeInterval(60)
        XCTAssertNotNil(store.record(sender: "+1 555 0100", text: "  your code is 123456 \n"))
        let other = IncomingMessageStore(supportDirectory: self.directory, now: { clock })
        let messages = other.messages(limit: 10)
        XCTAssertEqual(messages.map(\.text), ["your code is 123456", "dinner at 7?"], "newest first, trimmed")
        XCTAssertEqual(messages.map(\.sender), ["+1 555 0100", "Mom"])
        XCTAssertEqual(other.messages(since: clock.addingTimeInterval(-30), limit: 10).map(\.text), ["your code is 123456"])
        XCTAssertEqual(other.messages(limit: 1).count, 1)
        XCTAssertEqual(other.count, 2)
    }

    func testTheSameTextReportedTwiceWithinTwoMinutesIsOneMessage() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = IncomingMessageStore(supportDirectory: self.directory, now: { clock })
        XCTAssertNotNil(store.record(sender: "Mom", text: "ok"))
        clock = clock.addingTimeInterval(30)
        XCTAssertNil(store.record(sender: "Mom", text: "ok"), "Shortcuts ran the automation twice")
        XCTAssertNotNil(store.record(sender: "Dad", text: "ok"), "same text from someone else is a message")
        clock = clock.addingTimeInterval(IncomingMessageStore.duplicateWindow)
        XCTAssertNotNil(store.record(sender: "Mom", text: "ok"), "the same text later is a new message")
        XCTAssertNil(store.record(sender: "Mom", text: "   "), "an empty text is nothing")
        XCTAssertEqual(store.count, 3)
    }

    func testTheFeedIsBoundedInCountAndAge() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = IncomingMessageStore(supportDirectory: self.directory, now: { clock })
        store.record(sender: "Old", text: "from two weeks ago")
        clock = clock.addingTimeInterval(IncomingMessageStore.ageLimit + 1)
        for index in 0 ..< (IncomingMessageStore.countLimit + 5) {
            clock = clock.addingTimeInterval(1)
            store.record(sender: "S\(index)", text: "m\(index)")
        }
        let all = store.messages(limit: 10_000)
        XCTAssertEqual(all.count, IncomingMessageStore.countLimit)
        XCTAssertEqual(all.first?.text, "m\(IncomingMessageStore.countLimit + 4)", "the newest is kept")
        XCTAssertFalse(all.contains { $0.sender == "Old" }, "two weeks old is gone")
    }
    @MainActor
    func testSetupStatusIgnoresSentAndPrunesOldReceived() {
        var clock = Date()
        let store = IncomingMessageStore(supportDirectory: self.directory, now: { clock })
        let model = MessagesReadSetupModel(store: store)
        store.record(sender: "Mom", text: "hello", direction: .sent)
        model.refresh()
        XCTAssertNil(model.lastReceived)
        XCTAssertEqual(model.recordedCount, 0)
        store.record(sender: "Mom", text: "hello")
        store.record(sender: "Mom", text: "hello")
        model.refresh()
        XCTAssertEqual(model.recordedCount, 1)
        XCTAssertEqual(model.lastReceived?.direction, .received)
        clock = clock.addingTimeInterval(IncomingMessageStore.ageLimit + 1)
        model.refresh()
        XCTAssertNil(model.lastReceived)
        XCTAssertEqual(model.recordedCount, 0)
    }

    func testLegacyDecodingAndSentRoundTrip() throws {
        let legacy = Data(#"{"id":"old","sender":"Mom","text":"hello","receivedAt":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(IncomingMessage.self, from: legacy).direction, .received)
        let store = IncomingMessageStore(supportDirectory: self.directory)
        store.record(sender: "Mom, Dad", text: "hello", direction: .sent)
        store.record(sender: "Mom, Dad", text: "hello", direction: .sent)
        let reopened = IncomingMessageStore(supportDirectory: self.directory)
        XCTAssertEqual(reopened.count, 2, "two actual sends must not be deduplicated")
        XCTAssertEqual(reopened.messages(limit: 1).first?.direction, .sent)
        XCTAssertEqual(reopened.messages(limit: 1).first?.sender, "Mom, Dad")
    }

    @MainActor
    func testComposerOnlyRecordsSent() {
        let store = IncomingMessageStore(supportDirectory: self.directory)
        let composer = SystemMessageComposer(store: store)
        composer.recordCompletion(.cancelled, recipients: ["Mom"], body: "cancel")
        composer.recordCompletion(.failed, recipients: ["Mom"], body: "fail")
        XCTAssertEqual(store.count, 0)
        composer.recordCompletion(.sent, recipients: ["Mom", "Dad"], body: "edited text")
        XCTAssertEqual(store.messages(limit: 1).first?.text, "edited text")
        XCTAssertEqual(store.messages(limit: 1).first?.direction, .sent)
    }

}
