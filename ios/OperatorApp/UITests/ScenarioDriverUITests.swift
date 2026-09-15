import XCTest

// Drives a batch of connector QA scenarios through the real chat UI.
//
// The runner (ios/qa/connector-qa/run.mjs) writes a batch file, sets
// OPERATOR_QA=1 and OPERATOR_QA_BATCH=<path>, and starts this one test. For
// every step the driver types the prompt, taps Send, answers every approval or
// permission alert the way the step says, waits for a new assistant reply, and
// reports what it saw as one `QA-STEP {json}` line (also appended to the batch's
// resultsPath). It never judges a reply: the runner reads the persisted
// conversation and the app log for that.
//
// Operator's own permission layer (ConnectorPermissionCenter) is handled like
// the environment it is: the first-launch Permissions cover is dismissed, an
// in-chat "Operator wants to read X" banner is granted during a step (the
// runner scores that step `blocked`, since the model was told to stop), and a
// write acknowledgement is always declined - the driver never turns on a grant
// the owner must read a warning for. Those show up as alerts with source
// "permission", which the checks keep apart from the app's approval alerts.
//
// Every step spends one real model turn on the owner's ChatGPT account. Gated so
// the default scheme never runs it.

private struct Batch: Decodable {
    struct Step: Decodable {
        let stepKey: String
        let prompt: String
        /// "relaunch" terminates and relaunches the app first; "continue" sends into the open session.
        let launch: String
        /// "allow" taps Allow / Allow once on every approval; "deny" taps Cancel / Deny; "none" leaves alerts alone.
        let approve: String
    }
    let steps: [Step]
    let resultsPath: String
    let launchTimeoutSeconds: Double
    let replyTimeoutSeconds: Double
}

private struct AlertSeen: Encodable {
    let source: String
    let title: String
    let message: String
    let action: String
    let at: Double
}

private struct StepResult: Encodable {
    let stepKey: String
    var startedAt: Double
    var launched = false
    var readyAt: Double?
    var sentAt: Double?
    var doneAt: Double?
    var sawWorking = false
    var endedAt: Double?
    var appWasGone = false
    var alerts: [AlertSeen] = []
    var repliesBefore = 0
    var repliesAfter = 0
    var lastReplyLabel = ""
    var error: String?
}

private let headerTitles: Set<String> = [
    "Operator, Ready on this iPhone",
    "Operator, Working locally",
    "Operator, Starting Operator",
    "Operator, Saved — waiting for Operator",
]

@MainActor
final class ScenarioDriverUITests: XCTestCase {
    private var qaEnabled: Bool { ProcessInfo.processInfo.environment["OPERATOR_QA"] == "1" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testRunScenarioBatch() throws {
        try XCTSkipUnless(qaEnabled, "connector QA driver; run via run.mjs (OPERATOR_QA=1)")
        guard let batchPath = ProcessInfo.processInfo.environment["OPERATOR_QA_BATCH"] else {
            XCTFail("OPERATOR_QA_BATCH not set"); return
        }
        let batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var launched = false

        for step in batch.steps {
            var result = StepResult(stepKey: step.stepKey, startedAt: now())
            do {
                // A crash in the previous step leaves the app gone; start it
                // again rather than failing every remaining step of the batch.
                if launched, app.state != .runningForeground, app.state != .runningBackground {
                    result.appWasGone = true
                    launched = false
                }
                if step.launch == "relaunch" || !launched {
                    if launched { app.terminate() }
                    app.launch()
                    launched = true
                    result.launched = true
                }
                // A leftover alert from the previous step (approve: none, or a
                // permission sheet) would block the composer. Cancel is the safe
                // answer, and a leftover grant banner is dismissed rather than
                // granted so no step changes the grants outside its own window.
                handleAlerts(app: app, springboard: springboard, approve: "deny", grant: false, into: &result)
                try waitForReady(app, timeout: batch.launchTimeoutSeconds)
                result.readyAt = now()
                result.repliesBefore = assistantReplies(in: app).count

                let composer = app.textFields["chat-composer"]
                guard composer.waitForExistence(timeout: 10) else { throw DriverError.missing("chat-composer") }
                composer.tap()
                composer.typeKey("a", modifierFlags: .command)
                composer.typeText(XCUIKeyboardKey.delete.rawValue)
                composer.typeText(step.prompt)
                let send = app.buttons["Send"]
                guard send.waitForExistence(timeout: 5), send.isEnabled else { throw DriverError.missing("Send") }
                send.tap()
                result.sentAt = now()

                // Done when the app has been busy (Stop button or "Working locally")
                // and is then back to Ready with no Stop button for two polls in a
                // row. Bubble counts are not used to decide: the list is lazy, so the
                // number of visible assistant bubbles drops when the chat scrolls.
                let deadline = Date().addingTimeInterval(batch.replyTimeoutSeconds)
                var idlePolls = 0
                while Date() < deadline {
                    // Queries against a dead app are slow and fail the test; stop
                    // polling the moment it is gone.
                    if app.state == .notRunning { throw DriverError.appCrashed }
                    handleAlerts(app: app, springboard: springboard, approve: step.approve, grant: step.approve != "none", into: &result)
                    let busy = app.buttons["Stop Operator"].exists || app.staticTexts["Operator, Working locally"].exists
                    if busy { result.sawWorking = true; idlePolls = 0 }
                    let ready = app.staticTexts["Operator, Ready on this iPhone"].exists
                    if result.sawWorking, !busy, ready {
                        idlePolls += 1
                        if idlePolls >= 2 {
                            let replies = assistantReplies(in: app)
                            result.repliesAfter = replies.count
                            result.lastReplyLabel = replies.last ?? ""
                            result.doneAt = now()
                            break
                        }
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
                if app.state == .notRunning { throw DriverError.appCrashed }
                if result.doneAt == nil {
                    result.repliesAfter = assistantReplies(in: app).count
                    result.error = "reply-timeout"
                    attachScreenshot(app, name: "\(step.stepKey)-timeout")
                }
            } catch {
                if app.state == .notRunning || (error as? DriverError) == .appCrashed {
                    result.error = "app-crashed: \(error)"
                } else {
                    result.error = "\(error)"
                    attachScreenshot(app, name: "\(step.stepKey)-error")
                }
            }
            result.endedAt = now()
            report(result, to: batch.resultsPath)
        }
    }

    // MARK: readiness

    private func waitForReady(_ app: XCUIApplication, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // First launch after install: the Permissions page covers the chat
            // until the owner taps Continue. Nothing is granted by that tap.
            let cover = app.buttons["permissions-done"]
            if cover.exists, cover.isHittable { cover.tap() }
            if app.buttons["Connect ChatGPT"].exists { throw DriverError.blocked("model-not-signed-in") }
            if app.staticTexts["Operator, Ready on this iPhone"].exists { return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw DriverError.blocked("runtime-not-ready")
    }

    // MARK: alerts

    private func handleAlerts(app: XCUIApplication, springboard: XCUIApplication, approve: String, grant: Bool,
                              into result: inout StepResult) {
        let alert = app.alerts.firstMatch
        if alert.exists {
            let title = alert.label
            let message = (0..<alert.staticTexts.count)
                .map { alert.staticTexts.element(boundBy: $0).label }
                .filter { $0 != title }
                .joined(separator: "\n")
            let action = tap(alert, approve: approve,
                             allow: ["Allow", "Send"], deny: ["Cancel", "Don't Allow"])
            result.alerts.append(.init(source: "app", title: title, message: message, action: action, at: now()))
            return
        }
        let permission = springboard.alerts.firstMatch
        if permission.exists {
            let title = permission.label
            let action = tap(permission, approve: approve,
                             allow: ["Allow Full Access", "Allow While Using App", "Allow Once", "Allow", "OK"],
                             deny: ["Don't Allow", "Cancel"])
            result.alerts.append(.init(source: "springboard", title: title, message: "", action: action, at: now()))
            return
        }
        // A write grant that carries a warning (WhatsApp send) opens the
        // acknowledgement sheet. The driver never accepts it: that grant is the
        // owner's to make after reading the warning, and the QA banks hold no
        // scenario that needs it.
        let acknowledgement = app.buttons["acknowledgement-confirm"]
        if acknowledgement.exists {
            let leave = app.buttons["Leave it off"]
            let action = leave.exists ? "Leave it off" : "no-button"
            if leave.exists { leave.tap() }
            result.alerts.append(.init(source: "permission", title: "acknowledgement", message: "", action: action, at: now()))
            return
        }
        // The Permissions page, opened by a banner Allow that needed the
        // warning above, or the first-launch cover. Done/Continue closes it
        // without changing any grant.
        let page = app.buttons["permissions-done"]
        if page.exists, page.isHittable {
            page.tap()
            result.alerts.append(.init(source: "permission", title: "permissions-page", message: "", action: "Done", at: now()))
            return
        }
        // "Operator wants to read X": the model asked for something not yet
        // granted and was told to stop. Granting here lets the next repeat run;
        // the runner scores this step blocked from the log, not from this record.
        let allow = app.buttons["permission-banner-allow"]
        if allow.exists {
            let ask = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Operator wants to")).firstMatch
            let title = ask.exists ? ask.label : "grant request"
            var action = "left"
            if grant {
                allow.tap()
                action = "Allow"
            } else if app.buttons["Not now"].exists {
                app.buttons["Not now"].tap()
                action = "Not now"
            }
            result.alerts.append(.init(source: "permission", title: title, message: "", action: action, at: now()))
            return
        }
        let card = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Action needs your approval")).firstMatch
        if card.exists {
            let title = card.label
            let button = approve == "deny" ? card.buttons["Deny"] : card.buttons["Allow once"]
            var action = "left"
            if approve != "none", button.exists, button.isEnabled {
                button.tap()
                action = approve == "deny" ? "Deny" : "Allow once"
            }
            result.alerts.append(.init(source: "chat-card", title: title, message: "", action: action, at: now()))
        }
    }

    private func tap(_ alert: XCUIElement, approve: String, allow: [String], deny: [String]) -> String {
        if approve == "none" { return "left" }
        for label in (approve == "deny" ? deny : allow) {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return label }
        }
        return "no-button"
    }

    // MARK: reading the screen

    /// Assistant message bubbles on screen, header and progress labels excluded.
    private func assistantReplies(in app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "Operator, ")
        var out: [String] = []
        for query in [app.staticTexts, app.otherElements] {
            let matches = query.matching(predicate)
            for i in 0..<matches.count {
                let label = matches.element(boundBy: i).label
                if headerTitles.contains(label) { continue }
                out.append(String(label.dropFirst("Operator, ".count)))
            }
        }
        return out
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func report(_ result: StepResult, to path: String) {
        guard let data = try? JSONEncoder().encode(result), let line = String(data: data, encoding: .utf8) else { return }
        print("QA-STEP \(line)")
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            handle.closeFile()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func now() -> Double { Date().timeIntervalSince1970 }
}

private enum DriverError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case blocked(String)
    case appCrashed
    var description: String {
        switch self {
        case .appCrashed: "app-crashed"
        case let .missing(what): "missing-element:\(what)"
        case let .blocked(why): "blocked:\(why)"
        }
    }
}
