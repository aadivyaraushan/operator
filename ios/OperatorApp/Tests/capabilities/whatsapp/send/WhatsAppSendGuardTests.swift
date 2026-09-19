import Foundation
import XCTest
@testable import OperatorApp

@MainActor
final class WhatsAppSendGuardTests: XCTestCase {
    private struct Recipients: WhatsAppKnownRecipients {
        let jids: Set<String>
        func isKnown(jid: String) async throws -> Bool { self.jids.contains(jid) }
    }
    private final class History: WhatsAppSendHistoryStore, @unchecked Sendable {
        var dates: [Date] = []
        func loadSendDates() -> [Date] { self.dates }
        func saveSendDates(_ dates: [Date]) { self.dates = dates }
    }

    private func makeGuard(_ known: Set<String>, history: History = History(), clock: @escaping () -> Date) -> WhatsAppSendGuard {
        WhatsAppSendGuard(recipients: Recipients(jids: known), history: history, now: clock)
    }

    func testAStrangerIsRefusedBeforeAnythingElseAndNeverCountsAgainstThePace() async {
        let history = History()
        let g = self.makeGuard(["1@s.whatsapp.net"], history: history, clock: { Date(timeIntervalSince1970: 1_000) })
        let refusal = await g.check(recipientJID: "2@s.whatsapp.net")
        XCTAssertEqual(refusal, .unknownRecipient)
        XCTAssertEqual(refusal?.code, "RECIPIENT_UNKNOWN")
        XCTAssertEqual(history.dates, [])
        let ok = await g.check(recipientJID: "1@s.whatsapp.net")
        XCTAssertNil(ok)
    }

    func testSendsCloserThanTheMinimumGapAreRefusedWithARetryTime() async {
        var now = Date(timeIntervalSince1970: 10_000)
        let history = History()
        let g = self.makeGuard(["1@s.whatsapp.net"], history: history, clock: { now })
        let r1 = await g.check(recipientJID: "1@s.whatsapp.net")
        XCTAssertNil(r1)
        g.recordSend()
        now = now.addingTimeInterval(5)
        let r5 = await g.check(recipientJID: "1@s.whatsapp.net")
        XCTAssertEqual(r5, .tooSoon(retryAfterSeconds: 15))
        now = now.addingTimeInterval(15)
        let r2 = await g.check(recipientJID: "1@s.whatsapp.net")
        XCTAssertNil(r2)
    }

    func testTheDailyCapIsRollingAndSurvivesARelaunch() async {
        var now = Date(timeIntervalSince1970: 100_000)
        let history = History()
        var g = self.makeGuard(["1@s.whatsapp.net"], history: history, clock: { now })
        for _ in 0..<WhatsAppSendGuard.dailyCap {
            let r3 = await g.check(recipientJID: "1@s.whatsapp.net")
        XCTAssertNil(r3)
            g.recordSend()
            now = now.addingTimeInterval(60)
        }
        // A new guard over the same store: the count persisted.
        g = self.makeGuard(["1@s.whatsapp.net"], history: history, clock: { now })
        XCTAssertEqual(g.sendsInLast24Hours, WhatsAppSendGuard.dailyCap)
        guard case .dailyCapReached? = await g.check(recipientJID: "1@s.whatsapp.net") else { return XCTFail("expected the cap") }
        // 24 hours after the first send, one slot frees up.
        now = Date(timeIntervalSince1970: 100_000 + 86_400 + 1)
        let r4 = await g.check(recipientJID: "1@s.whatsapp.net")
        XCTAssertNil(r4)
        XCTAssertEqual(g.sendsInLast24Hours, WhatsAppSendGuard.dailyCap - 1)
    }

    func testAnUnreadableChatListMeansNobodyIsKnown() async {
        struct Failing: WhatsAppKnownRecipients { func isKnown(jid: String) async throws -> Bool { throw CocoaError(.fileReadUnknown) } }
        let g = WhatsAppSendGuard(recipients: Failing(), history: History(), now: Date.init)
        let r6 = await g.check(recipientJID: "1@s.whatsapp.net")
        XCTAssertEqual(r6, .unknownRecipient)
    }
}
