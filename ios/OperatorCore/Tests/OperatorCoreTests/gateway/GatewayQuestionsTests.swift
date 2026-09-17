import Foundation
import XCTest
@testable import OperatorCore

/// The gateway's question protocol, as Operator answers it. Payloads are the
/// shapes the bundled 2026.9.1 runtime broadcasts; the first one is the exact
/// question that hung the phone on 2026-09-16.
final class GatewayQuestionsTests: XCTestCase {
    private let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
    private let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#
    private let groupChatRecord = #"{"id":"ask_0123456789abcdef0123456789abcdef","questions":[{"questionId":"group_message","header":"Message","question":"What should I send in the Aadivya and Arnav group chat?","options":[{"label":"MVP update (Recommended)","description":"Ask to coordinate Spotify testing and improving the UX before the MVP is done."},{"label":"Call now","description":"Ask whether they’re free for a call right now."},{"label":"Meet tomorrow","description":"Ask when they’re both free to meet tomorrow."}],"multiSelect":false}],"agentId":"main","sessionKey":"agent:main:main","runId":"run-1","createdAtMs":1789617078505,"expiresAtMs":1789617978505,"status":"pending"}"#

    private func connect(_ incoming: [String], ids: [String]) async throws -> (OpenClawGatewayConnection, QuestionTestTransport) {
        let transport = QuestionTestTransport(incoming: [self.challenge, self.accepted] + incoming)
        let connection = OpenClawGatewayConnection(
            transport: transport, token: "local-token", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS 18.5.0", instanceID: "install-1"),
            requestID: QuestionRequestIDSequence(["connect-1"] + ids).next)
        try await connection.connect()
        return (connection, transport)
    }

    func testQuestionRequestedEventDecodesTheRecordThatHungThePhone() async throws {
        let event = #"{"type":"event","event":"question.requested","payload":\#(self.groupChatRecord)}"#
        let (connection, _) = try await self.connect([event], ids: [])

        guard case let .question(.requested(record)) = try await connection.receive() else {
            return XCTFail("Expected question.requested")
        }
        XCTAssertEqual(record.id, "ask_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(record.status, .pending)
        XCTAssertEqual(record.runID, "run-1")
        XCTAssertEqual(record.questions.count, 1)
        let question = try XCTUnwrap(record.questions.first)
        XCTAssertEqual(question.questionId, "group_message")
        XCTAssertEqual(question.header, "Message")
        XCTAssertEqual(question.options.map(\.label), ["MVP update (Recommended)", "Call now", "Meet tomorrow"])
        XCTAssertFalse(question.multiSelect)
        XCTAssertFalse(question.acceptsFreeText)
        XCTAssertTrue(record.isActionable(at: Date(timeIntervalSince1970: 1789617078.6)))
        XCTAssertFalse(record.isActionable(at: Date(timeIntervalSince1970: 1789617978.6)))
    }

    func testQuestionForAnotherSessionOrMalformedIsIgnoredNotFatal() async throws {
        let other = self.groupChatRecord.replacingOccurrences(of: "agent:main:main", with: "agent:other:main")
        let malformed = #"{"id":"ask_x","questions":[],"createdAtMs":1,"expiresAtMs":2,"status":"pending"}"#
        let oneOption = #"{"id":"ask_y","questions":[{"questionId":"q","question":"?","options":[{"label":"only"}]}],"createdAtMs":1,"expiresAtMs":2,"status":"pending"}"#
        let events = [other, malformed, oneOption].map { #"{"type":"event","event":"question.requested","payload":\#($0)}"# }
        let (connection, _) = try await self.connect(events, ids: [])

        for _ in events {
            guard case .ignored(event: "question.requested") = try await connection.receive() else {
                return XCTFail("Expected the record to be ignored")
            }
        }
    }

    func testFreeTextAndMultiSelectFlagsDecode() throws {
        let json = #"{"id":"ask_z","questions":[{"questionId":"name","header":"Name","question":"What should I call them?","options":[]},{"questionId":"days","header":"Days","question":"Which days?","options":[{"label":"Mon"},{"label":"Tue"}],"multiSelect":true,"isOther":true}],"createdAtMs":1,"expiresAtMs":2,"status":"pending"}"#
        let record = try JSONDecoder().decode(GatewayQuestionRecord.self, from: Data(json.utf8))
        XCTAssertTrue(record.questions[0].acceptsFreeText)
        XCTAssertFalse(record.questions[0].multiSelect)
        XCTAssertTrue(record.questions[1].multiSelect)
        XCTAssertTrue(record.questions[1].acceptsFreeText)
    }

    func testQuestionResolvedEventDecodesEachTerminalShape() async throws {
        let answered = #"{"type":"event","event":"question.resolved","payload":{"id":"ask_1","status":"answered","answers":{"answers":{"group_message":["Call now"]}}}}"#
        let cancelled = #"{"type":"event","event":"question.resolved","payload":{"id":"ask_2","status":"cancelled"}}"#
        let expired = #"{"type":"event","event":"question.resolved","payload":{"id":"ask_3","status":"expired"}}"#
        let (connection, _) = try await self.connect([answered, cancelled, expired], ids: [])

        guard case let .question(.resolved(first)) = try await connection.receive() else { return XCTFail("answered") }
        XCTAssertEqual(first, GatewayQuestionResolvedEvent(id: "ask_1", status: .answered, answers: .init(["group_message": ["Call now"]])))
        guard case let .question(.resolved(second)) = try await connection.receive() else { return XCTFail("cancelled") }
        XCTAssertEqual(second.status, .cancelled)
        guard case let .question(.resolved(third)) = try await connection.receive() else { return XCTFail("expired") }
        XCTAssertEqual(third.status, .expired)
    }

    func testListQuestionsKeepsThisSessionsRecordsOnly() async throws {
        let other = self.groupChatRecord.replacingOccurrences(of: "agent:main:main", with: "agent:other:main").replacingOccurrences(of: "ask_0123456789abcdef0123456789abcdef", with: "ask_other")
        let unscoped = self.groupChatRecord.replacingOccurrences(of: #""sessionKey":"agent:main:main","#, with: "").replacingOccurrences(of: "ask_0123456789abcdef0123456789abcdef", with: "ask_unscoped")
        let list = #"{"type":"res","id":"list-1","ok":true,"payload":{"questions":[\#(self.groupChatRecord),\#(other),\#(unscoped)]}}"#
        let (connection, transport) = try await self.connect([list], ids: ["list-1"])

        let questions = try await connection.listQuestions()

        XCTAssertEqual(questions.map(\.id), ["ask_0123456789abcdef0123456789abcdef", "ask_unscoped"])
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "question.list")
    }

    func testAnswerQuestionSendsTheGatewayShapeAndChecksTheRecordedAnswer() async throws {
        let resolved = #"{"type":"res","id":"resolve-1","ok":true,"payload":{"status":"answered","answers":{"answers":{"group_message":["Call now"]}}}}"#
        let (connection, transport) = try await self.connect([resolved], ids: ["resolve-1"])

        let result = try await connection.answerQuestion(
            id: "ask_0123456789abcdef0123456789abcdef",
            answers: .init(["group_message": ["Call now"]]))

        XCTAssertEqual(result.status, .answered)
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "question.resolve")
        XCTAssertEqual(params["id"] as? String, "ask_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(params["resolvedBy"] as? String, "operator-ios")
        XCTAssertNil(params["cancel"])
        let answers = try XCTUnwrap((params["answers"] as? [String: Any])?["answers"] as? [String: [String]])
        XCTAssertEqual(answers, ["group_message": ["Call now"]])
    }

    func testAnswerQuestionRejectsAGatewayThatRecordedSomethingElse() async throws {
        let mismatch = #"{"type":"res","id":"resolve-1","ok":true,"payload":{"status":"answered","answers":{"answers":{"group_message":["Meet tomorrow"]}}}}"#
        let (connection, _) = try await self.connect([mismatch], ids: ["resolve-1"])

        do {
            _ = try await connection.answerQuestion(id: "ask_1", answers: .init(["group_message": ["Call now"]]))
            XCTFail("A different recorded answer must not be reported as success")
        } catch OpenClawGatewayError.invalidFrame {}
    }

    func testAnswerQuestionRefusesEmptyAnswersBeforeSending() async throws {
        let (connection, transport) = try await self.connect([], ids: [])
        do {
            _ = try await connection.answerQuestion(id: "ask_1", answers: .init([:]))
            XCTFail("Empty answers must be refused")
        } catch OpenClawGatewayError.invalidFrame {}
        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1, "only the connect frame")
    }

    func testCancelQuestionSendsCancelAndChecksTheStatus() async throws {
        let cancelled = #"{"type":"res","id":"resolve-1","ok":true,"payload":{"status":"cancelled"}}"#
        let (connection, transport) = try await self.connect([cancelled], ids: ["resolve-1"])

        try await connection.cancelQuestion(id: "ask_1")

        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "question.resolve")
        XCTAssertEqual(params["cancel"] as? Bool, true)
        XCTAssertNil(params["answers"])
    }

    func testTerminalQuestionSurfacesAsGatewayRejection() async throws {
        // question.resolve on a finished record: INVALID_REQUEST with reason
        // QUESTION_ALREADY_TERMINAL. The caller treats it as "someone else
        // answered", not as a transport failure.
        let rejected = #"{"type":"res","id":"resolve-1","ok":false,"error":{"code":"INVALID_REQUEST","message":"question 'ask_1' is already answered","details":{"reason":"QUESTION_ALREADY_TERMINAL"}}}"#
        let (connection, _) = try await self.connect([rejected], ids: ["resolve-1"])
        do {
            _ = try await connection.answerQuestion(id: "ask_1", answers: .init(["q": ["a"]]))
            XCTFail("expected rejection")
        } catch OpenClawGatewayError.rejected(let code, _) {
            XCTAssertEqual(code, "INVALID_REQUEST")
        }
    }
}

private actor QuestionTestTransport: GatewayTransport {
    private var incoming: [Data]
    private var sent: [Data] = []

    init(incoming: [String]) {
        self.incoming = incoming.map { Data($0.utf8) }
    }

    func open() async throws {}

    func send(_ data: Data) async throws {
        self.sent.append(data)
    }

    func receive() async throws -> Data {
        guard !self.incoming.isEmpty else { throw QuestionTestTransportError.noMessage }
        return self.incoming.removeFirst()
    }

    func close() async {}

    func sentMessages() -> [Data] { self.sent }
}

private enum QuestionTestTransportError: Error {
    case noMessage
}

private final class QuestionRequestIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) { self.values = values }

    func next() -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.removeFirst()
    }
}
