import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundMessageDispatchServiceTests: XCTestCase {
    @MainActor private final class Recorder: GatewayNodeCommandHandler {
        var calls: [(command: String, params: String?)] = []
        let name: String
        init(_ name: String) { self.name = name }
        func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
            self.calls.append((command, paramsJSON))
            return .success(payloadJSON: #"{"via":"\#(self.name)"}"#)
        }
    }

    private let compose = #"{"recipients":["+12175550100"],"body":"running late"}"#

    func testWithoutTheGrantComposeOpensTheComposer() async {
        let composer = Recorder("compose"), sender = Recorder("send")
        var recorded: [String] = []
        let dispatch = ForegroundMessageDispatchService(compose: composer, send: sender, autosendAllowed: { false }, recordAutosend: { recorded.append($0) })
        let result = await dispatch.handleNodeCommand("sms.compose", paramsJSON: self.compose, timeoutMilliseconds: nil)
        XCTAssertEqual(result, .success(payloadJSON: #"{"via":"compose"}"#))
        XCTAssertEqual(composer.calls.map(\.command), ["sms.compose"])
        XCTAssertEqual(sender.calls.count, 0)
        XCTAssertEqual(recorded, [])
    }

    func testWithTheGrantASingleRecipientTextIsSentForTheOwner() async throws {
        let composer = Recorder("compose"), sender = Recorder("send")
        var recorded: [String] = []
        let dispatch = ForegroundMessageDispatchService(compose: composer, send: sender, autosendAllowed: { true }, recordAutosend: { recorded.append($0) })
        let result = await dispatch.handleNodeCommand("sms.compose", paramsJSON: self.compose, timeoutMilliseconds: nil)
        XCTAssertEqual(result, .success(payloadJSON: #"{"via":"send"}"#))
        XCTAssertEqual(composer.calls.count, 0)
        XCTAssertEqual(sender.calls.map(\.command), ["sms.send"])
        let params = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((sender.calls[0].params ?? "").utf8)) as? [String: String])
        XCTAssertEqual(params, ["recipient": "+12175550100", "body": "running late"])
        XCTAssertEqual(recorded, ["sms.send"], "the session log shows it went out without a tap")
    }

    func testGroupTextsAndOddShapesStillGoThroughTheComposerEvenWithTheGrant() async {
        let composer = Recorder("compose"), sender = Recorder("send")
        let dispatch = ForegroundMessageDispatchService(compose: composer, send: sender, autosendAllowed: { true })
        for params in [
            #"{"recipients":["+1","+2"],"body":"hi"}"#,
            #"{"recipients":[],"body":"hi"}"#,
            #"{"recipient":"+1","body":"hi"}"#,
            "not json", nil,
        ] {
            _ = await dispatch.handleNodeCommand("sms.compose", paramsJSON: params, timeoutMilliseconds: nil)
        }
        XCTAssertEqual(composer.calls.count, 5)
        XCTAssertEqual(sender.calls.count, 0)
    }

    func testOtherCommandsAreNotDispatched() async {
        let composer = Recorder("compose"), sender = Recorder("send")
        let dispatch = ForegroundMessageDispatchService(compose: composer, send: sender, autosendAllowed: { true })
        guard case let .failure(code, _) = await dispatch.handleNodeCommand("sms.send", paramsJSON: self.compose, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(code, "UNSUPPORTED_COMMAND")
        XCTAssertEqual(composer.calls.count + sender.calls.count, 0)
    }
}
