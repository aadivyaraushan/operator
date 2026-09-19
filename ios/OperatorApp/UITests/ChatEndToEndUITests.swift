import XCTest

// End-to-end proof of the FULL user path, driven through the real chat UI:
//
//   type a message  ->  the on-device LLM decides to call a connector
//                    ->  the connector runs against the owner's real account
//                    ->  the reply renders back in chat
//
// This launches the REAL app. No fake/stub gateway or model exists in the app
// (verified by code read), so a plain launch necessarily exercises the real
// embedded Node runtime + real model — which means the paid test SPENDS a small
// amount on the owner's ChatGPT device-code account. It is gated on
// OPERATOR_E2E=1 (set only by the OperatorAppE2E scheme) so it never runs by
// default / on CI. Ground truth that the connector actually fired is the app's
// own os_log line `[account-read] request ... operation=gmailMessages`
// (subsystem app.operator.ios, category account-read), captured by the caller
// around this run; this test additionally asserts a genuinely NEW reply rendered
// in chat.

@MainActor
final class ChatEndToEndUITests: XCTestCase {
    private var e2eEnabled: Bool { ProcessInfo.processInfo.environment["OPERATOR_E2E"] == "1" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // FREE smoke test (no LLM, no accounts): proves the harness compiles, the app
    // launches, and the chat composer is reachable. Runs on any sim, including the
    // throwaway one, so the paid test's mechanics are de-risked for $0.
    func testAppLaunchesAndChatComposerIsReachable() throws {
        let app = XCUIApplication()
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 150),
                      "chat composer never appeared — app launch / layout problem")
    }

    // PAID end-to-end test. Only runs under the OperatorAppE2E scheme.
    func testCheckMyEmailRoutesThroughLLMToGmailConnectorAndRepliesInChat() throws {
        try XCTSkipUnless(e2eEnabled,
            "paid end-to-end test; run via the OperatorAppE2E scheme (OPERATOR_E2E=1)")

        let app = XCUIApplication()
        app.launch()

        // The embedded runtime boots on foreground; readiness can take a while.
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 150),
                      "chat composer never appeared (runtime boot?)")

        // Pre-flight: the model must already be signed in, otherwise the LLM can't
        // run and this would not be a real end-to-end proof.
        if app.buttons["Connect ChatGPT"].waitForExistence(timeout: 5) {
            throw XCTSkip("app shows 'Connect ChatGPT' — the model is not signed in on this sim; sign in first")
        }

        // Snapshot the assistant bubbles already on screen so we can require a
        // genuinely NEW reply (chat history / drafts persist across launches).
        let before = Set(assistantReplies(in: app))

        // Focus and clear any persisted draft, then type a fresh prompt.
        composer.tap()
        clearField(composer)
        let prompt = "Check my Gmail inbox and tell me the sender and subject of my single most recent email."
        composer.typeText(prompt)

        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
        XCTAssertTrue(send.isEnabled, "Send should enable once non-whitespace is typed")
        send.tap()

        // Wait for a genuinely NEW assistant reply to appear (one not present
        // before this turn, and not the header/working/connect labels). A real
        // model reply plus a live connector round-trip can take a while.
        var reply = ""
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if let fresh = assistantReplies(in: app).first(where: { !before.contains($0) }),
               !fresh.isEmpty {
                reply = fresh
                break
            }
            Thread.sleep(forTimeInterval: 3)
        }
        print("E2E-REPLY <<<\(reply)>>>")
        XCTAssertFalse(reply.isEmpty, "no NEW assistant reply appeared within the timeout")

        // The reply must not be a hard "I can't reach your account" failure.
        let lower = reply.lowercased()
        for bad in ["not connected", "isn't connected", "is not connected", "can't access",
                    "cannot access", "unable to access", "don't have access", "do not have access",
                    "no access to your", "couldn't access", "could not access",
                    "need to connect", "please connect"] {
            XCTAssertFalse(lower.contains(bad),
                           "reply looks like a connector-access failure, not a real inbox result: \(reply)")
        }
    }

    // PAID end-to-end WRITE test. Proves the owner-gated send chain a real user
    // hits: type "send an email to myself" -> the on-device LLM calls
    // connections.write -> the app shows the on-phone owner-approval alert
    // ("Allow account action?") BEFORE any send -> tap Allow -> the real email
    // sends -> a confirming reply renders in chat. Sends a real email to the
    // owner's OWN address (ssdear@gmail.com), a pre-authorized safe recipient.
    // Ground truth captured by the caller: os_log `[location-node] handling
    // command=connections.write`. Only runs under the OperatorAppE2E scheme.
    func testSelfEmailSendRoutesThroughLLMOwnerApprovalAndSends() throws {
        try XCTSkipUnless(e2eEnabled,
            "paid end-to-end test; run via the OperatorAppE2E scheme (OPERATOR_E2E=1)")

        let app = XCUIApplication()
        app.launch()

        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 150),
                      "chat composer never appeared (runtime boot?)")

        if app.buttons["Connect ChatGPT"].waitForExistence(timeout: 5) {
            throw XCTSkip("app shows 'Connect ChatGPT' — the model is not signed in on this sim; sign in first")
        }

        let before = Set(assistantReplies(in: app))

        composer.tap()
        clearField(composer)
        // Self-send to the owner's own address (pre-authorized safe recipient).
        // Explicit recipient/subject/body so the LLM sends instead of asking.
        let prompt = "Send an email to ssdear@gmail.com with the subject "
            + "\"Operator E2E write test\" and the body "
            + "\"End-to-end write-path test — safe to ignore.\""
        composer.typeText(prompt)

        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
        XCTAssertTrue(send.isEnabled, "Send should enable once non-whitespace is typed")
        send.tap()

        // The LLM must reach connections.write, which gates the real send behind
        // the on-phone owner-approval alert. Wait for it, prove it's the
        // write-approval, capture its preview, then approve.
        let approval = app.alerts.firstMatch
        XCTAssertTrue(approval.waitForExistence(timeout: 200),
                      "no owner-approval alert appeared — the LLM did not reach connections.write")
        let title = approval.label
        print("E2E-WRITE-APPROVAL-TITLE <<<\(title)>>>")
        var preview = ""
        for i in 0..<approval.staticTexts.count {
            preview += approval.staticTexts.element(boundBy: i).label + " | "
        }
        print("E2E-WRITE-APPROVAL-PREVIEW <<<\(preview)>>>")
        XCTAssertTrue(title.localizedCaseInsensitiveContains("account action"),
                      "unexpected alert (not the write-approval): \(title)")

        let allow = approval.buttons["Allow"]
        XCTAssertTrue(allow.exists, "Allow button missing on the approval alert")
        allow.tap()

        // After approval the real send executes and the assistant confirms.
        var reply = ""
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let fresh = assistantReplies(in: app).first(where: { !before.contains($0) }),
               !fresh.isEmpty {
                reply = fresh
                break
            }
            Thread.sleep(forTimeInterval: 3)
        }
        print("E2E-WRITE-REPLY <<<\(reply)>>>")
        XCTAssertFalse(reply.isEmpty, "no confirming reply appeared after approving the send")

        let lower = reply.lowercased()
        for bad in ["not connected", "isn't connected", "is not connected", "can't send",
                    "cannot send", "unable to send", "couldn't send", "could not send",
                    "need to connect", "please connect", "failed to send"] {
            XCTAssertFalse(lower.contains(bad),
                           "reply looks like a send failure, not a confirmation: \(reply)")
        }
    }

    /// All assistant message-bubble texts currently on screen (with the leading
    /// "Operator, " stripped), excluding the header / working / connect labels.
    private func assistantReplies(in app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "Operator, ")
        let prefix = "Operator, "
        var out: [String] = []
        for query in [app.staticTexts, app.otherElements] {
            let matches = query.matching(predicate)
            for i in 0..<matches.count {
                let label = matches.element(boundBy: i).label
                if label.hasPrefix("Operator, Ready")
                    || label.hasPrefix("Operator, Working")
                    || label.hasPrefix("Operator, Connect") { continue }
                out.append(String(label.dropFirst(prefix.count)))
            }
        }
        return out
    }

    /// Select-all + delete to clear a persisted draft from a focused text field.
    private func clearField(_ field: XCUIElement) {
        field.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
    }
}
