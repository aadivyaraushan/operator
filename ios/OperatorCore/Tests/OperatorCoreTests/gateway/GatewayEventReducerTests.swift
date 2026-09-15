import XCTest
@testable import OperatorCore

final class GatewayEventReducerTests: XCTestCase {
    func testHistoryRecoveryUsesExplicitSourceIdentityNotMessageOrder() throws {
        let data = Data(#"{"messages":[{"role":"assistant","stopReason":"stop","content":"Recovered reply","__openclaw":{"runId":"recovery-run","sourceRunId":"original-run"}},{"role":"assistant","stopReason":"error","content":"Recovery error","__openclaw":{"runId":"recovery-run","sourceRunId":"original-run"}},{"role":"assistant","stopReason":"stop","content":"Unrelated later reply","__openclaw":{"runId":"other-run","sourceRunId":"other-source"}}]}"#.utf8)
        let history = try JSONDecoder().decode(GatewayChatHistoryResult.self, from: data)
        XCTAssertEqual(history.exactAssistantReply(runID: "original-run"), "Recovered reply")
        XCTAssertEqual(history.exactAssistantReply(runID: "recovery-run"), "Recovered reply")
        XCTAssertNil(history.exactAssistantReply(runID: "unknown"))
    }

    func testHistoryRecoveryAcceptsPlainTextAlongsideContentBlocks() throws {
        let data = Data(#"{"messages":[{"role":"user","content":"Open website"},{"role":"assistant","content":"Opened","stopReason":"stop","__openclaw":{"runId":"run"}}]}"#.utf8)
        let history = try JSONDecoder().decode(GatewayChatHistoryResult.self, from: data)
        XCTAssertEqual(history.exactAssistantReply(runID: "run"), "Opened")
    }

    func testHistoryRecoveryReadsNativeRunIDAndSkipsToolStepsAndErrors() throws {
        let data = Data(#"{"messages":[{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Website opened"}],"__openclaw":{"runId":"run"}},{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"Opening"}],"__openclaw":{"runId":"run"}},{"role":"assistant","stopReason":"error","content":[{"type":"text","text":"Retry failed"}],"__openclaw":{"runId":"run"}},{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Other reply"}],"__openclaw":{"runId":"other","idempotencyKey":"run"}}]}"#.utf8)
        let history = try JSONDecoder().decode(GatewayChatHistoryResult.self, from: data)
        XCTAssertEqual(history.exactAssistantReply(runID: "run"), "Website opened")
        XCTAssertNil(history.exactAssistantReply(runID: "missing"))
    }

    func testHistoryRecoverySelectsOnlyReadableAssistantForExactRun() throws {
        let data = Data(#"{"messages":[{"role":"assistant","content":[{"type":"text","text":"unrelated"}],"__openclaw":{"idempotencyKey":"other"}},{"role":"user","content":[{"type":"text","text":"same key user"}],"__openclaw":{"idempotencyKey":"run"}},{"role":"assistant","content":[{"type":"text","text":"Exact reply"}],"__openclaw":{"idempotencyKey":"run"}}]}"#.utf8)
        let history = try JSONDecoder().decode(GatewayChatHistoryResult.self, from: data)

        XCTAssertEqual(history.exactAssistantReply(runID: "run"), "Exact reply")
        XCTAssertNil(history.exactAssistantReply(runID: "missing"))
    }

    func testHistoryRecoveryRejectsEmptyExactReplyInsteadOfUsingLatestUnrelatedText() throws {
        let data = Data(#"{"messages":[{"role":"assistant","content":[],"__openclaw":{"idempotencyKey":"run"}},{"role":"assistant","content":[{"type":"text","text":"latest unrelated"}],"__openclaw":{"idempotencyKey":"other"}}]}"#.utf8)
        let history = try JSONDecoder().decode(GatewayChatHistoryResult.self, from: data)

        XCTAssertNil(history.exactAssistantReply(runID: "run"))
    }
    func testChatSendEncodesCurrentOpenClawWireContract() throws {
        let request = GatewayRequestFactory.chatSend(
            requestID: "send-1",
            sessionKey: "agent:main:main",
            message: "hello",
            idempotencyKey: "message-1")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "req")
        XCTAssertEqual(object["id"] as? String, "send-1")
        XCTAssertEqual(object["method"] as? String, "chat.send")
        XCTAssertEqual(params["sessionKey"] as? String, "agent:main:main")
        XCTAssertEqual(params["message"] as? String, "hello")
        XCTAssertNil(params["fastMode"], "Per-message overrides bypass OpenClaw restart-safe admission")
        XCTAssertEqual(params["idempotencyKey"] as? String, "message-1")
    }

    func testCurrentChatEventFrameWireNamesDecode() throws {
        let data = Data(#"{"type":"event","event":"chat","seq":91,"payload":{"runId":"run-1","sessionKey":"agent:main:main","seq":3,"state":"delta","deltaText":"Hi","replace":true}}"#.utf8)

        let frame = try JSONDecoder().decode(GatewayEventFrame<GatewayChatEvent>.self, from: data)

        XCTAssertEqual(frame.event, "chat")
        XCTAssertEqual(frame.sequence, 91)
        XCTAssertEqual(frame.payload.runID, "run-1")
        XCTAssertEqual(frame.payload.sequence, 3)
        XCTAssertEqual(frame.payload.deltaText, "Hi")
        XCTAssertTrue(frame.payload.replace)
    }

    func testChatSendResponseDecodesRunIdentifier() throws {
        let data = Data(#"{"type":"res","id":"send-1","ok":true,"payload":{"runId":"run-1","status":"started"}}"#.utf8)

        let response = try JSONDecoder().decode(GatewayResponseFrame.self, from: data)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.payload?.runID, "run-1")
        XCTAssertEqual(response.payload?.status, "started")
    }

    func testDeltaThenReplaceThenFinalProducesOneReplyAndIgnoresDuplicates() {
        var reducer = GatewayEventReducer(sessionKey: "agent:main:main")

        XCTAssertEqual(
            reducer.apply(.init(runID: "run-1", sessionKey: "agent:main:main", sequence: 1, state: .status)),
            [.working(runID: "run-1")])
        XCTAssertEqual(
            reducer.apply(.init(runID: "run-1", sessionKey: "agent:main:main", sequence: 2, state: .delta, deltaText: "Hel")),
            [.stream(runID: "run-1", text: "Hel")])
        XCTAssertEqual(
            reducer.apply(.init(runID: "run-1", sessionKey: "agent:main:main", sequence: 3, state: .delta, deltaText: "Hello", replace: true)),
            [.stream(runID: "run-1", text: "Hello")])
        XCTAssertEqual(
            reducer.apply(.init(runID: "run-1", sessionKey: "agent:main:main", sequence: 4, state: .final)),
            [.reply(runID: "run-1", text: "Hello")])
        XCTAssertEqual(
            reducer.apply(.init(runID: "run-1", sessionKey: "agent:main:main", sequence: 4, state: .final)),
            [])
    }

    func testFinalWithoutReadableTextReportsUnverifiedFailure() {
        var emptyReducer = GatewayEventReducer(sessionKey: "main")
        XCTAssertEqual(
            emptyReducer.apply(.init(
                runID: "empty",
                sessionKey: "main",
                sequence: 1,
                state: .final,
                messageText: " \n\t")),
            [
                .working(runID: "empty"),
                .failed(
                    runID: "empty",
                    message: "No readable result was received. Completion isn't verified.")
            ])

        var whitespaceStreamReducer = GatewayEventReducer(sessionKey: "main")
        _ = whitespaceStreamReducer.apply(.init(
            runID: "whitespace-stream",
            sessionKey: "main",
            sequence: 1,
            state: .delta,
            deltaText: "  \n"))
        XCTAssertEqual(
            whitespaceStreamReducer.apply(.init(
                runID: "whitespace-stream",
                sessionKey: "main",
                sequence: 2,
                state: .final,
                messageText: "\t")),
            [
                .failed(
                    runID: "whitespace-stream",
                    message: "No readable result was received. Completion isn't verified.")
            ])

        var finalMessageReducer = GatewayEventReducer(sessionKey: "main")
        _ = finalMessageReducer.apply(.init(
            runID: "final-message",
            sessionKey: "main",
            sequence: 1,
            state: .delta,
            deltaText: " \n"))
        XCTAssertEqual(
            finalMessageReducer.apply(.init(
                runID: "final-message",
                sessionKey: "main",
                sequence: 2,
                state: .final,
                messageText: "Readable final")),
            [.reply(runID: "final-message", text: "Readable final")])
    }

    func testWrongSessionAndOutOfOrderEventsAreIgnored() {
        var reducer = GatewayEventReducer(sessionKey: "main")

        XCTAssertEqual(
            reducer.apply(.init(runID: "other", sessionKey: "different", sequence: 1, state: .delta, deltaText: "no")),
            [])
        XCTAssertEqual(
            reducer.apply(.init(runID: "run", sessionKey: "main", sequence: 2, state: .delta, deltaText: "new")),
            [.working(runID: "run"), .stream(runID: "run", text: "new")])
        XCTAssertEqual(
            reducer.apply(.init(runID: "run", sessionKey: "main", sequence: 1, state: .delta, deltaText: "old")),
            [])
    }

    func testErrorAndAbortAreTerminal() {
        var reducer = GatewayEventReducer(sessionKey: "main")

        XCTAssertEqual(
            reducer.apply(.init(runID: "failed", sessionKey: "main", sequence: 1, state: .error, errorMessage: "model unavailable")),
            [.working(runID: "failed"), .failed(runID: "failed", message: "model unavailable")])
        XCTAssertEqual(
            reducer.apply(.init(runID: "stopped", sessionKey: "main", sequence: 1, state: .aborted)),
            [.working(runID: "stopped"), .stopped(runID: "stopped")])
    }
}
