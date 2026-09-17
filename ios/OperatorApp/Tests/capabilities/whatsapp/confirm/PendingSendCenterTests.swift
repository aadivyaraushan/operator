import Foundation
import XCTest
@testable import OperatorApp

@MainActor
final class PendingSendCenterTests: XCTestCase {
    private final class Notifier: SendConfirmationNotifying {
        var asked: [(id: String, name: String, body: String)] = []
        var withdrawn: [String] = []
        var reports: [(title: String, body: String)] = []
        func askToConfirm(id: String, recipientName: String, body: String) { self.asked.append((id, recipientName, body)) }
        func withdraw(id: String) { self.withdrawn.append(id) }
        func report(title: String, body: String) { self.reports.append((title, body)) }
    }

    private final class Sender: WhatsAppTextSending, @unchecked Sendable {
        var sent: [WhatsAppComposeRequest] = []
        var fail = false
        struct Failed: Error {}
        func send(_ request: WhatsAppComposeRequest, timeoutMilliseconds: Int) async throws -> NativeWhatsAppSendResult {
            if self.fail { throw Failed() }
            self.sent.append(request)
            return .init(outcome: "sent", messageId: "m1")
        }
    }

    private final class Recipients: WhatsAppKnownRecipients, @unchecked Sendable {
        var known: Set<String>
        init(_ known: Set<String>) { self.known = known }
        func isKnown(jid: String) async throws -> Bool { self.known.contains(jid) }
    }

    private final class History: WhatsAppSendHistoryStore, @unchecked Sendable {
        var dates: [Date] = []
        func loadSendDates() -> [Date] { self.dates }
        func saveSendDates(_ dates: [Date]) { self.dates = dates }
    }

    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
        self.clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    private func center(_ notifier: Notifier, _ sender: Sender, known: Set<String> = ["villa@s.whatsapp.net"], recorded: (@MainActor (PendingSend) async -> Void)? = nil) -> (PendingSendCenter, PendingSendStore, History) {
        let history = History()
        let store = PendingSendStore(supportDirectory: self.directory, now: { self.clock })
        let guardrail = WhatsAppSendGuard(recipients: Recipients(known), history: history, now: { self.clock })
        let center = PendingSendCenter(store: store, notifier: notifier, sender: sender, guardrail: guardrail, recordSent: recorded ?? { _ in }, now: { self.clock })
        return (center, store, history)
    }

    func testAskPostsTheQuestionAndTheTapSendsRecordsAndReportsOnce() async throws {
        let notifier = Notifier()
        let sender = Sender()
        var recorded: [PendingSend] = []
        let (center, store, history) = self.center(notifier, sender, recorded: { recorded.append($0) })
        let request = WhatsAppComposeRequest(recipientJID: "villa@s.whatsapp.net", body: "when are we gonna play basketball bro")

        guard case let .asked(id) = await center.ask(request, recipientName: "Villa") else { return XCTFail() }
        XCTAssertEqual(notifier.asked.map(\.name), ["Villa"])
        XCTAssertEqual(notifier.asked.first?.body, request.body)
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(sender.sent.isEmpty, "nothing goes out on the ask")

        self.clock = self.clock.addingTimeInterval(90)
        let outcome = await center.perform(id: id)
        XCTAssertEqual(outcome, .sent(recipientName: "Villa"))
        XCTAssertEqual(sender.sent, [request])
        XCTAssertEqual(history.dates.count, 1, "the send counts against the pace")
        XCTAssertEqual(recorded.map(\.body), [request.body])
        XCTAssertEqual(notifier.withdrawn, [id], "the question comes down when it is answered")
        XCTAssertEqual(notifier.reports.map(\.title), ["Sent to Villa"])
        XCTAssertEqual(store.count, 0)

        let again = await center.perform(id: id)
        XCTAssertEqual(again, .expired, "a second tap on the same notification sends nothing")
        XCTAssertEqual(sender.sent.count, 1)
    }

    func testTheGuardRunsBeforeTheQuestionAndAgainAtTheTap() async {
        let notifier = Notifier()
        let sender = Sender()
        let (center, store, history) = self.center(notifier, sender, known: ["villa@s.whatsapp.net"])

        let stranger = await center.ask(.init(recipientJID: "stranger@s.whatsapp.net", body: "hi"), recipientName: "Stranger")
        XCTAssertEqual(stranger, .refused(.unknownRecipient))
        XCTAssertTrue(notifier.asked.isEmpty, "a refused send never becomes a notification")
        XCTAssertEqual(store.count, 0)

        guard case let .asked(id) = await center.ask(.init(recipientJID: "villa@s.whatsapp.net", body: "yo"), recipientName: "Villa") else { return XCTFail() }
        // Something else sent to WhatsApp a moment ago; the tap must respect the gap.
        history.dates = [self.clock.addingTimeInterval(-5)]
        self.clock = self.clock.addingTimeInterval(1)
        let outcome = await center.perform(id: id)
        guard case .refused(.tooSoon) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.reports.first?.title, "Not sent to Villa")
    }

    func testDeclineExpiryReplacementAndAFailedSendAllLeaveNothingSent() async {
        let notifier = Notifier()
        let sender = Sender()
        let (center, store, _) = self.center(notifier, sender)

        guard case let .asked(first) = await center.ask(.init(recipientJID: "villa@s.whatsapp.net", body: "first"), recipientName: "Villa") else { return XCTFail() }
        guard case let .asked(second) = await center.ask(.init(recipientJID: "villa@s.whatsapp.net", body: "second"), recipientName: "Villa") else { return XCTFail() }
        XCTAssertEqual(notifier.withdrawn, [first], "a newer draft to the same person replaces the older question")
        XCTAssertEqual(store.count, 1)

        center.decline(id: second)
        XCTAssertEqual(store.count, 0)
        let declined = await center.perform(id: second)
        XCTAssertEqual(declined, .expired)
        XCTAssertTrue(sender.sent.isEmpty)

        guard case let .asked(late) = await center.ask(.init(recipientJID: "villa@s.whatsapp.net", body: "late"), recipientName: "Villa") else { return XCTFail() }
        self.clock = self.clock.addingTimeInterval(PendingSendStore.expiry + 1)
        let expired = await center.perform(id: late)
        XCTAssertEqual(expired, .expired, "ten minutes later the draft is gone")
        XCTAssertEqual(notifier.reports.last?.title, "Not sent")

        guard case let .asked(failing) = await center.ask(.init(recipientJID: "villa@s.whatsapp.net", body: "fail"), recipientName: "Villa") else { return XCTFail() }
        sender.fail = true
        let failed = await center.perform(id: failing)
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(notifier.reports.last?.title, "Couldn't send to Villa")
        XCTAssertEqual(store.count, 0)
    }

    private final class Presenter: WhatsAppComposePresenter {
        var decision: WhatsAppComposeDecision = .denied
        var asked: [WhatsAppComposeRequest] = []
        func confirm(_ request: WhatsAppComposeRequest) async -> WhatsAppComposeDecision { self.asked.append(request); return self.decision }
        func cancel() {}
    }

    func testATapOnTheNotificationItselfAsksAgainInTheAlert() async {
        let notifier = Notifier()
        let sender = Sender()
        let (center, store, _) = self.center(notifier, sender)
        let presenter = Presenter()

        guard case let .asked(first) = await center.ask(.init(recipientJID: "villa@s.whatsapp.net", body: "yo"), recipientName: "Villa") else { return XCTFail() }
        let declined = await center.confirmOnScreen(id: first, presenter: presenter)
        XCTAssertEqual(declined, .declined)
        XCTAssertEqual(presenter.asked.map(\.body), ["yo"])
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(store.count, 0, "Cancel in the alert drops the draft")
        XCTAssertEqual(notifier.withdrawn, [first])

        guard case let .asked(second) = await center.ask(.init(recipientJID: "villa@s.whatsapp.net", body: "yo again"), recipientName: "Villa") else { return XCTFail() }
        presenter.decision = .confirmed(.init(recipientJID: "villa@s.whatsapp.net", body: "yo again"))
        let sent = await center.confirmOnScreen(id: second, presenter: presenter)
        XCTAssertEqual(sent, .sent(recipientName: "Villa"))
        XCTAssertEqual(sender.sent.map(\.body), ["yo again"])
        XCTAssertEqual(notifier.reports.map(\.title), ["Sent to Villa"])
    }

    func testTheStoreSurvivesAnotherInstance() {
        let store = PendingSendStore(supportDirectory: self.directory, now: { self.clock })
        let send = PendingSend(id: "a", recipientJID: "villa@s.whatsapp.net", recipientName: "Villa", body: "hi", createdAt: self.clock)
        XCTAssertNil(store.add(send))
        let other = PendingSendStore(supportDirectory: self.directory, now: { self.clock })
        XCTAssertEqual(other.take(id: "a"), send)
        XCTAssertNil(other.take(id: "a"))
    }
}
