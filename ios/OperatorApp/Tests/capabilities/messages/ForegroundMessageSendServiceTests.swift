import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundMessageSendServiceTests: XCTestCase {
    private final class FakeRunner: ShortcutRunner {
        var opens: [URL] = []
        var result = true
        func run(_ url: URL) async -> Bool { self.opens.append(url); return self.result }
    }

    func testHandsTheMessageToTheNamedShortcutAndNeverClaimsDelivery() async throws {
        let runner = FakeRunner()
        let service = ForegroundMessageSendService(runner: runner, isAppActive: { true })

        let result = await service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":" +1 217 555 0100 ","body":"running late, 10 min"}"#, timeoutMilliseconds: nil)

        guard case let .success(payload) = result else { return XCTFail("expected success") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["handedToShortcut"] as? Bool, true)
        XCTAssertEqual(object["sent"] as? Bool, false)
        XCTAssertEqual(object["deliveryVerified"] as? Bool, false)
        XCTAssertTrue((object["nextStep"] as? String ?? "").contains("do not say it was delivered"))

        let url = try XCTUnwrap(runner.opens.first)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "shortcuts")
        XCTAssertEqual(components.host, "x-callback-url")
        XCTAssertEqual(components.path, "/run-shortcut")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["name"], "Operator Send Message")
        XCTAssertEqual(query["input"], "text")
        XCTAssertEqual(query["x-success"], "app.operator.ios://shortcut/success")
        XCTAssertEqual(query["x-error"], "app.operator.ios://shortcut/error")
        XCTAssertEqual(query["x-cancel"], "app.operator.ios://shortcut/cancel")
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((query["text"] ?? "").utf8)) as? [String: String])
        XCTAssertEqual(input, ["to": "+1 217 555 0100", "body": "running late, 10 min"], "recipient trimmed, body verbatim")
    }

    func testRefusesBadShapesBeforeTouchingShortcuts() async throws {
        let runner = FakeRunner()
        let service = ForegroundMessageSendService(runner: runner, isAppActive: { true })
        for params in [
            nil, "", "not json", "[]",
            #"{"recipient":"+1","body":"hi","extra":1}"#,
            #"{"recipients":["+1"],"body":"hi"}"#,
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
        let service = ForegroundMessageSendService(runner: runner, isAppActive: { true })

        let result = await service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"+1","body":"hi"}"#, timeoutMilliseconds: nil)

        guard case let .failure(code, message) = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(code, "SHORTCUT_UNAVAILABLE")
        XCTAssertTrue(message.contains("Operator Send Message"))
        XCTAssertTrue(message.contains("Nothing was sent"))
    }

    func testInactiveAppAndOtherCommandsAreRefused() async throws {
        let runner = FakeRunner()
        let inactive = ForegroundMessageSendService(runner: runner, isAppActive: { false })
        guard case let .failure(code, _) = await inactive.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"+1","body":"hi"}"#, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(code, "APP_NOT_ACTIVE")
        guard case let .failure(other, _) = await inactive.handleNodeCommand("sms.compose", paramsJSON: nil, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(other, "UNSUPPORTED_COMMAND")
        XCTAssertEqual(runner.opens, [])
    }

    func testCallbackOutcomesAreRecognisedOnlyOnOperatorsOwnScheme() {
        XCTAssertEqual(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/success")!), "success")
        XCTAssertEqual(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/error")!), "error")
        XCTAssertEqual(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/cancel")!), "cancel")
        XCTAssertNil(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://shortcut/delivered")!))
        XCTAssertNil(ForegroundMessageSendService.callbackOutcome(URL(string: "app.operator.ios://oauth/callback")!))
        XCTAssertNil(ForegroundMessageSendService.callbackOutcome(URL(string: "https://example.com/shortcut/success")!))
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
