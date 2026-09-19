import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class MessageConversationServiceTests: XCTestCase {
    @MainActor
    private final class Sender: GatewayNodeCommandHandler {
        var calls = 0
        var result: GatewayNodeCommandResult = .success(payloadJSON: "{\"outcome\":\"success\"}")
        func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
            self.calls += 1
            return self.result
        }
    }
    private func fixture(canSend: @escaping () -> Bool = { true }) -> (MessageConversationService, MessageConversationStore, Sender) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = MessageConversationStore(supportDirectory: directory)
        let sender = Sender()
        let service = MessageConversationService(store: store, incoming: IncomingMessageStore(supportDirectory: directory), sender: sender,
            canRead: { true }, canSend: canSend, isActive: { true })
        return (service, store, sender)
    }
    func testOwnerRequestedTaskStartsAutomaticallyOnceWhenSendingEnabled() async throws {
        let (service, store, sender) = self.fixture()
        let params = #"{"operation":"propose","requestID":"one","recipient":"+12175550100","recipientName":"Aadivya","questions":["Homework?","Dinner?"],"initialMessage":"Homework and dinner plans?"}"#
        let result = await service.handleNodeCommand("messages.conversation", paramsJSON: params, timeoutMilliseconds: nil)
        guard case .success = result else { return XCTFail("expected proposal") }
        XCTAssertEqual(sender.calls, 1)
        let task = try XCTUnwrap(store.list().first)
        _ = await service.handleNodeCommand("messages.conversation", paramsJSON: params, timeoutMilliseconds: nil)
        XCTAssertEqual(sender.calls, 1)
        await service.approve(task.id, automatic: true)
        XCTAssertEqual(sender.calls, 1)
        XCTAssertNotNil(try store.list().first?.initialSentAt)
    }
    func testProposalWithAutomaticSendingOffStaysInlineWithoutSending() async throws {
        let (service, store, sender) = self.fixture(canSend: { false })
        let params = #"{"operation":"propose","requestID":"one","recipient":"+12175550100","recipientName":"Aadivya","questions":["Dinner?"],"initialMessage":"Dinner plans?"}"#
        let result = await service.handleNodeCommand("messages.conversation", paramsJSON: params, timeoutMilliseconds: nil)
        guard case .success = result else { return XCTFail("expected saved task") }
        XCTAssertEqual(sender.calls, 0)
        XCTAssertEqual(try store.list().first?.status, .proposed)
    }

    func testRevokedSendPermissionBlocksApproval() async throws {
        let (service, store, sender) = self.fixture(canSend: { false })
        let task = try store.propose(requestID: "one", recipient: "+12175550100", name: "A", questions: ["Dinner?"], initialMessage: "Dinner?")
        await service.approve(task.id, automatic: true)
        XCTAssertEqual(sender.calls, 0)
        XCTAssertEqual(try store.list().first?.status, .proposed)
    }
    func testUnknownSendStopsWithoutRetry() async throws {
        let (service, store, sender) = self.fixture()
        sender.result = .success(payloadJSON: "{\"outcome\":\"unknown\"}")
        let task = try store.propose(requestID: "one", recipient: "+12175550100", name: "A", questions: ["Dinner?"], initialMessage: "Dinner?")
        await service.approve(task.id, automatic: true)
        await service.send(task.id, ownerApproved: true)
        XCTAssertEqual(sender.calls, 1)
        XCTAssertEqual(try store.list().first?.sendState, .unknown)
    }
    func testModelCannotApproveOrResumeOrSendDirectly() async {
        let (service, _, sender) = self.fixture()
        for op in ["approve", "resume", "send"] {
            let result = await service.handleNodeCommand("messages.conversation", paramsJSON: "{\"operation\":\"\(op)\",\"taskID\":\"anything\"}", timeoutMilliseconds: nil)
            guard case .failure = result else { return XCTFail("must refuse \(op)") }
        }
        XCTAssertEqual(sender.calls, 0)
    }
    func testReviewPayloadResolvesOnlyTheAnsweredQuestion() async throws {
        let (service, store, sender) = self.fixture()
        let task = try store.propose(requestID: "one", recipient: "+12175550100", name: "A", questions: ["Homework?", "Dinner?"], initialMessage: "Homework and dinner?")
        await service.approve(task.id, automatic: false)
        _ = try store.receive(.init(id: "reply", sender: task.recipient, text: "Homework is chapter 3", receivedAt: Date()))
        let revision = try XCTUnwrap(store.list().first?.revision)
        let answers = [["questionID": task.questions[0].id, "messageID": "reply", "quote": "chapter 3", "answer": "Chapter 3"]]
        let payload: [String: Any] = ["taskID": task.id, "revision": revision, "followupMessage": "Nice, and dinner?",
            "answersJSON": String(decoding: try JSONSerialization.data(withJSONObject: answers), as: UTF8.self)]
        let result = await service.handleNodeCommand("messages.conversation.review", paramsJSON: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self), timeoutMilliseconds: nil)
        guard case .success = result else { return XCTFail("expected review success: \(result)") }
        XCTAssertEqual(try store.list().first?.outstanding.map(\.question), ["Dinner?"])
        XCTAssertEqual(try store.list().first?.pendingMessage, "Nice, and dinner?")
        XCTAssertEqual(sender.calls, 1, "review saves the agent reply, never sends it directly")
    }

}
