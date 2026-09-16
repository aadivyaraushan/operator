import Foundation
import XCTest
import OperatorCore
@testable import OperatorApp

@MainActor
final class ForegroundWhatsAppComposeServiceTests: XCTestCase {
    private final class Presenter: WhatsAppComposePresenter {
        var decision: WhatsAppComposeDecision = .denied
        var confirmed: [WhatsAppComposeRequest] = []
        func confirm(_ request: WhatsAppComposeRequest) async -> WhatsAppComposeDecision { self.confirmed.append(request); return self.decision }
        func cancel() {}
    }

    private final class Sender: WhatsAppTextSending, @unchecked Sendable {
        var sent: [WhatsAppComposeRequest] = []
        func send(_ request: WhatsAppComposeRequest, timeoutMilliseconds: Int) async throws -> NativeWhatsAppSendResult { self.sent.append(request); return .init(outcome: "sent", messageId: "m1") }
    }

    private final class Notifier: SendConfirmationNotifying {
        var asked: [(id: String, name: String, body: String)] = []
        func askToConfirm(id: String, recipientName: String, body: String) { self.asked.append((id, recipientName, body)) }
        func withdraw(id: String) {}
        func report(title: String, body: String) {}
    }

    private struct Recipients: WhatsAppKnownRecipients { let known: Set<String>; func isKnown(jid: String) async throws -> Bool { self.known.contains(jid) } }
    private final class History: WhatsAppSendHistoryStore, @unchecked Sendable { var dates: [Date] = []; func loadSendDates() -> [Date] { self.dates }; func saveSendDates(_ dates: [Date]) { self.dates = dates } }
    private struct Names: WhatsAppRecipientNaming { let names: [String: String]; func name(forJID jid: String) async -> String? { self.names[jid] } }

    private let villa = "15551234567@s.whatsapp.net"
    private let params = #"{"recipientJID":"15551234567@s.whatsapp.net","body":"u free tomorrow?"}"#
    private var directory: URL!

    override func setUp() {
        super.setUp()
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("compose-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: self.directory); super.tearDown() }

    private func guardrail(known: Set<String>) -> WhatsAppSendGuard { WhatsAppSendGuard(recipients: Recipients(known: known), history: History()) }

    private func center(_ notifier: Notifier, _ sender: Sender, known: Set<String>) -> PendingSendCenter {
        PendingSendCenter(store: PendingSendStore(supportDirectory: self.directory), notifier: notifier, sender: sender, guardrail: self.guardrail(known: known), recordSent: { _ in })
    }

    private func decode(_ result: GatewayNodeCommandResult) -> WhatsAppComposeAskedPayload? {
        guard case let .success(json) = result else { return nil }
        return try? JSONDecoder().decode(WhatsAppComposeAskedPayload.self, from: Data(json.utf8))
    }

    func testOffScreenWithoutACenterStillRefuses() async {
        let service = ForegroundWhatsAppComposeService(presenter: Presenter(), sender: Sender(), isAppActive: { false }, guardrail: self.guardrail(known: [self.villa]))
        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: self.params, timeoutMilliseconds: 5_000)
        guard case let .failure(code, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(code, "APP_NOT_ACTIVE")
    }

    func testOffScreenTheQuestionGoesOutAsANotificationAndNothingIsSent() async {
        let presenter = Presenter(); presenter.decision = .confirmed(.init(recipientJID: self.villa, body: "u free tomorrow?"))
        let sender = Sender(); let notifier = Notifier()
        let service = ForegroundWhatsAppComposeService(
            presenter: presenter, sender: sender, isAppActive: { false }, guardrail: self.guardrail(known: [self.villa]),
            confirmations: self.center(notifier, sender, known: [self.villa]), names: Names(names: [self.villa: "Villa"]))

        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: self.params, timeoutMilliseconds: 5_000)
        guard let payload = self.decode(result) else { return XCTFail("\(result)") }
        XCTAssertFalse(payload.sent)
        XCTAssertTrue(payload.askedByNotification)
        XCTAssertEqual(payload.outcome, "asked")
        XCTAssertEqual(payload.recipientName, "Villa")
        XCTAssertEqual(payload.expiresInSeconds, 600)
        XCTAssertTrue(payload.note.contains("Nothing has been sent"))
        XCTAssertEqual(notifier.asked.map(\.name), ["Villa"])
        XCTAssertEqual(notifier.asked.first?.body, "u free tomorrow?")
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertTrue(presenter.confirmed.isEmpty, "no alert off screen")
    }

    func testOffScreenAStrangerIsRefusedBeforeAnyNotification() async {
        let sender = Sender(); let notifier = Notifier()
        let service = ForegroundWhatsAppComposeService(
            presenter: Presenter(), sender: sender, isAppActive: { false }, guardrail: self.guardrail(known: []),
            confirmations: self.center(notifier, sender, known: []), names: Names(names: [:]))
        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: self.params, timeoutMilliseconds: 5_000)
        guard case let .failure(code, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(code, WhatsAppSendRefusal.unknownRecipient.code)
        XCTAssertTrue(notifier.asked.isEmpty)
    }

    func testOnScreenTheAlertStillDecidesAndTheCenterIsNotUsed() async {
        let presenter = Presenter(); presenter.decision = .confirmed(.init(recipientJID: self.villa, body: "u free tomorrow?"))
        let sender = Sender(); let notifier = Notifier()
        let service = ForegroundWhatsAppComposeService(
            presenter: presenter, sender: sender, isAppActive: { true }, guardrail: self.guardrail(known: [self.villa]),
            confirmations: self.center(notifier, sender, known: [self.villa]), names: Names(names: [self.villa: "Villa"]))
        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: self.params, timeoutMilliseconds: 5_000)
        guard case let .success(json) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(json.contains(#""outcome":"sent""#))
        XCTAssertEqual(presenter.confirmed.count, 1)
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertTrue(notifier.asked.isEmpty)
    }

    func testTheNotificationNamesTheNumberWhenTheStoreHasNoName() async {
        let sender = Sender(); let notifier = Notifier()
        let service = ForegroundWhatsAppComposeService(
            presenter: Presenter(), sender: sender, isAppActive: { false }, guardrail: self.guardrail(known: [self.villa]),
            confirmations: self.center(notifier, sender, known: [self.villa]), names: Names(names: [:]))
        _ = await service.handleNodeCommand("whatsapp.compose", paramsJSON: self.params, timeoutMilliseconds: 5_000)
        XCTAssertEqual(notifier.asked.map(\.name), ["+15551234567"])
        XCTAssertEqual(ForegroundWhatsAppComposeService.fallbackName(forJID: "1203630@g.us"), "a group")
        XCTAssertEqual(ForegroundWhatsAppComposeService.fallbackName(forJID: "odd"), "odd")
    }
}
