import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundMessageSendServiceTests: XCTestCase {
    private final class FakeRunner: ShortcutRunner {
        var opens: [URL] = []
        var result = true
        let coordinator: ShortcutSendCoordinator
        /// The outcome the callback delivers once the shortcut "opens"; nil
        /// leaves the wait hanging (for the timeout test).
        var callback: ShortcutSendCoordinator.Outcome? = .success
        init() {
            let box = Box()
            self.coordinator = ShortcutSendCoordinator(runner: box, timeout: .milliseconds(200))
            box.owner = self
        }
        func run(_ url: URL) async -> Bool { self.opens.append(url); return self.result }
        /// Bridges the coordinator's runner call back to this fake, then plays
        /// the callback the app would deliver from onOpenURL.
        final class Box: ShortcutRunner {
            weak var owner: FakeRunner?
            func run(_ url: URL) async -> Bool {
                guard let owner else { return false }
                let opened = await owner.run(url)
                if opened, let outcome = owner.callback {
                    Task { @MainActor in owner.coordinator.resolve(outcome) }
                }
                return opened
            }
        }
    }

    private func service(_ runner: FakeRunner, isAppActive: @escaping @MainActor @Sendable () -> Bool = { true }) -> ForegroundMessageSendService {
        ForegroundMessageSendService(coordinator: runner.coordinator, isAppActive: isAppActive)
    }

    func testHandsTheMessageToTheNamedShortcutAndNeverClaimsDelivery() async throws {
        let runner = FakeRunner()
        let service = self.service(runner)

        let result = await service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":" +1 217 555 0100 ","body":"running late, 10 min"}"#, timeoutMilliseconds: nil)

        guard case let .success(payload) = result else { return XCTFail("expected success") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["handedToShortcut"] as? Bool, true)
        XCTAssertEqual(object["sent"] as? Bool, true, "x-success means the shortcut ran")
        XCTAssertEqual(object["outcome"] as? String, "success")
        XCTAssertEqual(object["deliveryVerified"] as? Bool, false)
        XCTAssertTrue((object["nextStep"] as? String ?? "").contains("do not say it was delivered"))

        let url = try XCTUnwrap(runner.opens.first)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "shortcuts")
        XCTAssertEqual(components.host, "x-callback-url")
        XCTAssertEqual(components.path, "/run-shortcut")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["name"], "OperatorSendMessage")
        XCTAssertEqual(query["input"], "text")
        XCTAssertEqual(query["x-success"], "app.operator.ios://shortcut/success")
        XCTAssertEqual(query["x-error"], "app.operator.ios://shortcut/error")
        XCTAssertEqual(query["x-cancel"], "app.operator.ios://shortcut/cancel")
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((query["text"] ?? "").utf8)) as? [String: String])
        XCTAssertEqual(input, ["to": "+1 217 555 0100", "body": "running late, 10 min"], "recipient trimmed, body verbatim")
    }

    func testAGroupIsHandedToTheShortcutAsAListOfRecipients() async throws {
        let runner = FakeRunner()
        let service = self.service(runner)
        let result = await service.handleNodeCommand("sms.send", paramsJSON: #"{"recipients":[" +12175550100 ","ann@example.com"],"body":"dinner at 7?"}"#, timeoutMilliseconds: nil)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        let url = try XCTUnwrap(runner.opens.first)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((query["text"] ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(input["to"] as? [String], ["+12175550100", "ann@example.com"], "a list, trimmed, in the order given")
        XCTAssertEqual(input["body"] as? String, "dinner at 7?")
        XCTAssertEqual(query["name"], "OperatorSendMessage")
    }

    func testRefusesBadShapesBeforeTouchingShortcuts() async throws {
        let runner = FakeRunner()
        let service = self.service(runner)
        let eleven = (1...11).map { "\"+1217555010\($0)\"" }.joined(separator: ",")
        for params in [
            nil, "", "not json", "[]",
            #"{"recipient":"+1","body":"hi","extra":1}"#,
            #"{"recipients":["+1"],"body":"hi"}"#,
            #"{"recipients":[\#(eleven)],"body":"hi"}"#,
            #"{"recipients":["+1","+1"],"body":"hi"}"#,
            #"{"recipients":["+1",""],"body":"hi"}"#,
            #"{"recipients":["+1",2],"body":"hi"}"#,
            #"{"recipient":"","body":"hi"}"#,
            #"{"recipient":"+1","body":"   "}"#,
            #"{"recipient":"+1"}"#,
        ] {
            let result = await service.handleNodeCommand("sms.send", paramsJSON: params, timeoutMilliseconds: nil)
            guard case let .failure(code, _) = result else { return XCTFail("expected refusal for \(params ?? "nil")") }
            XCTAssertEqual(code, "INVALID_REQUEST", params ?? "nil")
        }
        XCTAssertEqual(runner.opens, [])
    }

    func testAMissingShortcutIsReportedAsSetupNotAsAFailedSend() async throws {
        let runner = FakeRunner()
        runner.result = false
        let service = self.service(runner)

        let result = await service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"+1","body":"hi"}"#, timeoutMilliseconds: nil)

        guard case let .failure(code, message) = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(code, "SHORTCUT_UNAVAILABLE")
        XCTAssertTrue(message.contains("OperatorSendMessage"))
        XCTAssertTrue(message.contains("Nothing was sent"))
    }

    func testInactiveAppAndOtherCommandsAreRefused() async throws {
        let runner = FakeRunner()
        let inactive = self.service(runner, isAppActive: { false })
        guard case let .failure(code, _) = await inactive.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"+1","body":"hi"}"#, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(code, "APP_NOT_ACTIVE")
        guard case let .failure(other, _) = await inactive.handleNodeCommand("sms.compose", paramsJSON: nil, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(other, "UNSUPPORTED_COMMAND")
        XCTAssertEqual(runner.opens, [])
    }

    func testTheShortcutsOutcomeIsReturnedSoTheModelKnowsAndCanContinue() async throws {
        for (outcome, sent, label) in [(ShortcutSendCoordinator.Outcome.error, false, "error"), (.cancel, false, "cancel")] {
            let runner = FakeRunner()
            runner.callback = outcome
            let result = await self.service(runner).handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"+1","body":"hi"}"#, timeoutMilliseconds: nil)
            guard case let .success(payload) = result else { return XCTFail("expected a payload for \(label)") }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(object["sent"] as? Bool, sent, label)
            XCTAssertEqual(object["outcome"] as? String, label)
        }
    }

    func testNoCallbackTimesOutAsUnknownRatherThanClaimingASend() async throws {
        let runner = FakeRunner()
        runner.callback = nil // the shortcut never reports back
        let result = await self.service(runner).handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"+1","body":"hi"}"#, timeoutMilliseconds: nil)
        guard case let .success(payload) = result else { return XCTFail("expected a payload") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["sent"] as? Bool, false)
        XCTAssertEqual(object["outcome"] as? String, "unknown")
        XCTAssertTrue((object["nextStep"] as? String ?? "").contains("do not resend"))
    }

    func testCoordinatorReportsSendingAcrossTheHopThenClears() async throws {
        let runner = FakeRunner()
        runner.callback = nil
        let coordinator = runner.coordinator
        XCTAssertFalse(coordinator.isSending)
        async let outcome = coordinator.send(URL(string: "shortcuts://x-callback-url/run-shortcut")!)
        // Give the open a moment, then resolve as the app would.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.isSending, "the runtime is kept alive while a send is out")
        coordinator.resolve(.success)
        let result = await outcome
        XCTAssertEqual(result, .success)
        XCTAssertFalse(coordinator.isSending)
    }

    func testCallbackOutcomesAreRecognisedOnlyOnOperatorsOwnScheme() {
        XCTAssertEqual(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/success")!), "success")
        XCTAssertEqual(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/error")!), "error")
        XCTAssertEqual(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/cancel")!), "cancel")
        XCTAssertNil(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/delivered")!))
        XCTAssertNil(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://oauth/callback")!))
        XCTAssertNil(ForegroundMessageSendService.callbackOutcome(URL(string: "https://example.com/shortcut/success")!))
    }

    func testInstallOpensAnICloudShortcutLinkAndTheSharedFileIsCheckedIn() throws {
        let url = ForegroundMessageSendService.installURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.icloud.com", "only an iCloud share link installs; see the comment on installURL")
        XCTAssertTrue(url.path.hasPrefix("/shortcuts/"))
        let checkedIn = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/shortcuts/\(ForegroundMessageSendService.shortcutName).shortcut")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkedIn.path), checkedIn.path)
    }

    func testAutosendIsItsOwnGrantSeparateFromTheComposer() {
        var grants = ConnectorGrants.none
        grants.set(.messages, .write, allowed: true)
        XCTAssertEqual(grants.decision(for: "sms.compose", paramsJSON: nil), .allowed(.messages, .write))
        XCTAssertEqual(grants.decision(for: "sms.send", paramsJSON: nil), .denied(.messagesAutosend, .write), "allowing the composer must not allow sending without a tap")
        XCTAssertFalse(GatewayNodeAgentTools.descriptors(permittedBy: {
            var all = ConnectorGrants.none
            for id in ConnectorID.allCases { all.set(id, .write, allowed: true) }
            return all
        }()).contains { $0.command == "sms.send" }, "never offered as a tool the model can reach for on its own")
    }
}
