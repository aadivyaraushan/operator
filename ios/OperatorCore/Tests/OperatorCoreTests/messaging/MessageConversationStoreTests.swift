import XCTest
@testable import OperatorCore

final class MessageConversationStoreTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_800_000_000) }
    private var directory: URL!
    private var clock: Clock!
    private var store: MessageConversationStore!
    override func setUp() {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.clock = Clock()
        let clock = self.clock!
        self.store = MessageConversationStore(supportDirectory: self.directory, now: { clock.date })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: self.directory) }
    private func proposed() throws -> MessageConversation {
        try self.store.propose(requestID: "request", recipient: "+12175550100", name: "Aadivya", questions: ["What is the CS374 homework?", "What are the dinner plans?"], initialMessage: "What is the CS374 homework, and what are the dinner plans?")
    }
    private func started() throws -> MessageConversation {
        let task = try self.proposed()
        try self.store.approve(task.id, automaticFollowups: true)
        _ = try self.store.reserveSend(task.id)
        try self.store.finishSend(task.id, outcome: .sent)
        return try XCTUnwrap(self.store.list().first)
    }
    private func receive(_ text: String, id: String = UUID().uuidString, sender: String = "+12175550100") throws -> String {
        self.clock.date += 1
        _ = try self.store.receive(.init(id: id, sender: sender, text: text, receivedAt: self.clock.date))
        return id
    }
    func testPartialAnswerOnlyFollowsUpOnDinnerAndThenCompletes() throws {
        let task = try self.started()
        let hw = try self.receive("CS374: problems 1 and 2")
        XCTAssertNil(try self.store.claimReview(), "let multi-part replies arrive")
        self.clock.date += 61
        let review = try XCTUnwrap(self.store.claimReview())
        XCTAssertNil(try self.store.claimReview(), "review is leased")
        try self.store.review(task.id, revision: review.revision, answers: [.init(questionID: task.questions[0].id, messageID: hw, quote: "problems 1 and 2", answer: "Problems 1 and 2")], followupMessage: "And what are the dinner plans?")
        let partial = try XCTUnwrap(self.store.list().first)
        XCTAssertEqual(partial.status, .active)
        XCTAssertEqual(partial.outstanding.map(\.question), ["What are the dinner plans?"])
        XCTAssertFalse(try XCTUnwrap(partial.pendingMessage).contains("CS374"))
        let send = try self.store.reserveSend(task.id)
        XCTAssertTrue(send.body.contains("dinner"))
        XCTAssertThrowsError(try self.store.reserveSend(task.id), "one durable reservation")
        try self.store.finishSend(task.id, outcome: .sent)
        let dinner = try self.receive("Dinner at 7 at home")
        self.clock.date += 61
        let last = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: last.revision, answers: [.init(questionID: task.questions[1].id, messageID: dinner, quote: "Dinner at 7 at home", answer: "7 at home")])
        XCTAssertEqual(try self.store.list().first?.status, .completed)
        XCTAssertThrowsError(try self.store.reserveSend(task.id))
    }
    func testUncertainPartialAnswerDoesNotFollowUp() throws {
        let task = try self.started()
        let id = try self.receive("homework is 1, checking dinner")
        self.clock.date += 61
        let review = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: review.revision, answers: [.init(questionID: task.questions[0].id, messageID: id, quote: "homework is 1", answer: "1")], followupMessage: nil)
        XCTAssertNil(try self.store.list().first?.pendingMessage)
        XCTAssertEqual(try self.store.list().first?.outstanding.count, 1)
    }

    func testConfidentUnansweredReplyCanFollowUpWithoutAnyResolvedQuestion() throws {
        let task = try self.started()
        _ = try self.receive("How about we figure that out?")
        self.clock.date += 61
        let review = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: review.revision, answers: [], followupMessage: "And what are the dinner plans?")
        XCTAssertNotNil(try self.store.list().first?.pendingMessage)
        _ = try self.store.reserveSend(task.id)
    }

    func testPartialProgressUsesAgentsReplyVerbatim() throws {
        let task = try self.started()
        let id = try self.receive("done w q1 for the cs 374 hw")
        self.clock.date += 61
        let review = try XCTUnwrap(self.store.claimReview())
        let reply = "nice, what are you thinking for dinner?"
        try self.store.review(task.id, revision: review.revision, answers: [.init(questionID: task.questions[0].id, messageID: id, quote: "done w q1", answer: "Q1 is done", remainingQuestion: "Anything else left?")], followupMessage: reply)
        XCTAssertEqual(try self.store.list().first?.questions[0].answer, "Q1 is done")
        XCTAssertEqual(try self.store.reserveSend(task.id).body, reply)
    }

    func testMigrationDropsOldTemplatedDraftForFreshAgentReview() throws {
        let task = try self.started()
        _ = try self.receive("done w q1")
        self.clock.date += 61
        let review = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: review.revision, answers: [], followupMessage: "Following up on the remaining questions: Homework? Dinner?")
        try self.store.migrateToAgentReplies()
        XCTAssertNil(try self.store.list().first?.pendingMessage)
        XCTAssertNotNil(try self.store.claimReview())
    }

    func testEachIncomingMessageRestartsTheFullMinuteQuietPeriod() throws {
        _ = try self.started()
        _ = try self.receive("Q1 is done")
        self.clock.date += 59
        XCTAssertNil(try self.store.claimReview())
        _ = try self.receive("checking dinner")
        self.clock.date += 59
        XCTAssertNil(try self.store.claimReview(), "a second message restarts the quiet period")
        self.clock.date += 1
        XCTAssertNotNil(try self.store.claimReview(), "review begins after a full quiet minute")
    }

    func testDuplicateProposalAndMismatchedIdempotencyKey() throws {
        let task = try self.proposed()
        XCTAssertEqual(try self.proposed().id, task.id)
        XCTAssertThrowsError(try self.store.propose(requestID: "request", recipient: "+12175550101", name: "Other", questions: ["Hello?"], initialMessage: "Hello?"))
        XCTAssertEqual(try self.store.list().count, 1)
    }
    func testExactIdentityOldAndDuplicateMessages() throws {
        let task = try self.started()
        _ = try self.receive("wrong person", sender: "+12175550101")
        _ = try self.receive("ambiguous name", sender: "Aadivya")
        _ = try self.store.receive(.init(id: "old", sender: task.recipient, text: "old", receivedAt: task.createdAt - 20))
        _ = try self.receive("yes", id: "same")
        _ = try self.receive("yes", id: "same")
        XCTAssertEqual(try self.store.list().first?.evidence.count, 1)
    }
    func testStaleAndFabricatedEvidenceAreRejectedAtomically() throws {
        let task = try self.started()
        let id = try self.receive("homework done")
        self.clock.date += 61
        let snapshot = try XCTUnwrap(self.store.claimReview())
        _ = try self.receive("another message")
        XCTAssertThrowsError(try self.store.review(task.id, revision: snapshot.revision, answers: []))
        let revision = try XCTUnwrap(self.store.list().first?.revision)
        XCTAssertThrowsError(try self.store.review(task.id, revision: revision, answers: [.init(questionID: task.questions[0].id, messageID: id, quote: "Dinner", answer: "7")]))
        XCTAssertEqual(try self.store.list().first?.outstanding.count, 2)
    }
    func testPauseCancelAndExpiryPreventSending() throws {
        let task = try self.proposed()
        try self.store.approve(task.id, automaticFollowups: true)
        try self.store.control(task.id, action: "pause")
        XCTAssertThrowsError(try self.store.reserveSend(task.id))
        try self.store.control(task.id, action: "resume")
        self.clock.date += 86401
        XCTAssertThrowsError(try self.store.reserveSend(task.id))
        XCTAssertEqual(try self.store.list().first?.status, .expired)
    }
    func testInterruptedSendDoesNotRetryAfterRelaunch() throws {
        let task = try self.proposed()
        try self.store.approve(task.id, automaticFollowups: true)
        _ = try self.store.reserveSend(task.id)
        let reloaded = MessageConversationStore(supportDirectory: self.directory)
        try reloaded.recoverInterruptedSends()
        XCTAssertEqual(try reloaded.list().first?.sendState, .unknown)
        XCTAssertThrowsError(try reloaded.reserveSend(task.id))
    }
    func testReviewModeRequiresOwnerApprovalAndNewReplyInvalidatesDraft() throws {
        let task = try self.proposed()
        try self.store.approve(task.id, automaticFollowups: false)
        _ = try self.store.reserveSend(task.id)
        try self.store.finishSend(task.id, outcome: .sent)
        let id = try self.receive("homework is 1")
        self.clock.date += 601
        let snapshot = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: snapshot.revision, answers: [.init(questionID: task.questions[0].id, messageID: id, quote: "homework is 1", answer: "1")], followupMessage: "And what are the dinner plans?")
        XCTAssertThrowsError(try self.store.reserveSend(task.id))
        _ = try self.receive("dinner later")
        XCTAssertThrowsError(try self.store.reserveSend(task.id, ownerApproved: true))
    }
    func testCorruptStorageFailsClosed() throws {
        _ = try self.proposed()
        try Data("bad".utf8).write(to: self.directory.appendingPathComponent("Operator/message-conversations.json"))
        XCTAssertThrowsError(try self.store.list())
        XCTAssertThrowsError(try self.proposed())
    }
    func testAgentWritesRepliesWithoutTemplateOrTwoReplyLimit() throws {
        let task = try self.started()
        for n in 0..<3 {
            _ = try self.receive("Still figuring it out \(n)")
            self.clock.date += 61
            let review = try XCTUnwrap(self.store.claimReview())
            let body = "Natural reply \(n)"
            try self.store.review(task.id, revision: review.revision, answers: [], followupMessage: body)
            XCTAssertEqual(try self.store.reserveSend(task.id).body, body)
            try self.store.finishSend(task.id, outcome: .sent)
        }
        XCTAssertEqual(try self.store.list().first?.followupMessages, ["Natural reply 0", "Natural reply 1", "Natural reply 2"])
        _ = try self.receive("another reply")
        self.clock.date += 61
        let review = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: review.revision, answers: [], followupMessage: "Natural reply 2")
        XCTAssertNil(try self.store.list().first?.pendingMessage)
    }

    func testFastReplyBeforeSendCallbackIsRetained() throws {
        let task = try self.proposed()
        try self.store.approve(task.id, automaticFollowups: true)
        _ = try self.store.reserveSend(task.id)
        _ = try self.receive("fast reply")
        try self.store.finishSend(task.id, outcome: .sent)
        XCTAssertEqual(try self.store.list().first?.evidence.count, 1)
    }

    func testRefusalStopsAndIrrelevantReplyDoesNotSend() throws {
        let task = try self.started()
        _ = try self.receive("hey")
        self.clock.date += 61
        var review = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: review.revision, answers: [])
        XCTAssertNil(try self.store.list().first?.pendingMessage)
        _ = try self.receive("please stop")
        self.clock.date += 61
        review = try XCTUnwrap(self.store.claimReview())
        try self.store.review(task.id, revision: review.revision, answers: [], stopReason: "Recipient asked to stop")
        XCTAssertEqual(try self.store.list().first?.status, .needsAttention)
        XCTAssertThrowsError(try self.store.reserveSend(task.id))
    }

    func testFailedModelReviewsHaveABoundedRetryBudget() throws {
        _ = try self.started()
        _ = try self.receive("reply")
        self.clock.date += 61
        for _ in 0..<3 {
            XCTAssertNotNil(try self.store.claimReview())
            self.clock.date += 301
        }
        XCTAssertNil(try self.store.claimReview())
        XCTAssertEqual(try self.store.list().first?.status, .needsAttention)
    }

}
