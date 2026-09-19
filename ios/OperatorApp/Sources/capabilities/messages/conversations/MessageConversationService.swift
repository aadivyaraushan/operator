import Combine
import Foundation
import OperatorCore

@MainActor
final class MessageConversationService: ObservableObject, GatewayNodeCommandHandler {
    @Published private(set) var tasks: [MessageConversation] = []
    @Published private(set) var error: String?
    @Published private(set) var isSending = false
    let store: MessageConversationStore
    private var seenIncoming: Set<String> = []
    private let incoming: IncomingMessageStore
    private let sender: any GatewayNodeCommandHandler
    private let canRead: () -> Bool
    private let canSend: () -> Bool
    private let isActive: () -> Bool

    init(store: MessageConversationStore, incoming: IncomingMessageStore, sender: any GatewayNodeCommandHandler,
         canRead: @escaping () -> Bool, canSend: @escaping () -> Bool, isActive: @escaping () -> Bool) {
        self.store = store; self.incoming = incoming; self.sender = sender
        self.canRead = canRead; self.canSend = canSend; self.isActive = isActive
        do { try store.recoverInterruptedSends(); try store.migrateToAgentReplies() } catch { self.error = error.localizedDescription }
        self.refresh()
    }

    var automaticMessagingEnabled: Bool { self.canRead() && self.canSend() }

    func refresh() {
        do { self.tasks = try self.store.list() } catch { self.error = error.localizedDescription }
    }

    func approve(_ id: String, automatic: Bool) async {
        guard !self.isSending else { self.error = "Wait for the current send to finish."; return }
        guard self.canRead(), self.canSend() else {
            self.error = "Enable Messages Read, Act and Messages, sent for you. Turn off Read-only to send."; return
        }
        do {
            try self.store.approve(id, automaticFollowups: automatic)
            ReplyNotifier.requestPermissionIfNeeded()
            await self.send(id, ownerApproved: true)
        } catch { self.error = error.localizedDescription }
        self.refresh()
    }

    func control(_ id: String, action: String) {
        do { try self.store.control(id, action: action); self.error = nil }
        catch { self.error = error.localizedDescription }
        self.refresh()
    }

    func send(_ id: String, ownerApproved: Bool = false) async {
        guard !self.isSending, self.isActive(), self.canRead(), self.canSend() else {
            self.error = "Sending needs Operator open and Messages Read, Act and sent-for-you permission."; return
        }
        self.isSending = true
        defer { self.isSending = false; self.refresh() }
        do {
            let reservation = try self.store.reserveSend(id, ownerApproved: ownerApproved)
            let data = try JSONSerialization.data(withJSONObject: ["recipient": reservation.recipient, "body": reservation.body])
            let result = await self.sender.handleNodeCommand("sms.send", paramsJSON: String(decoding: data, as: UTF8.self), timeoutMilliseconds: nil)
            let outcome: MessageConversationStore.SendOutcome
            switch result {
            case let .success(payload):
                let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
                switch object?["outcome"] as? String {
                case "success": outcome = .sent
                case "error", "cancel": outcome = .failed
                default: outcome = .unknown
                }
            case .failure: outcome = .failed
            }
            try self.store.finishSend(id, outcome: outcome)
            self.error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Foreground only. Recovery also catches texts captured while suspended.
    func tick(chat: ChatSessionModel) async {
        guard self.isActive(), self.canRead(), !self.isSending else { return }
        do {
            let messages = self.incoming.messages(limit: IncomingMessageStore.countLimit)
            self.seenIncoming.formIntersection(Set(messages.map(\.id)))
            for message in messages.reversed() where message.direction == .received && !self.seenIncoming.contains(message.id) {
                _ = try self.store.receive(.init(id: message.id, sender: message.sender, text: message.text, receivedAt: message.receivedAt))
                self.seenIncoming.insert(message.id)
            }
            self.refresh()
            // Existing active tasks follow the current global messaging permission.
            for task in self.tasks where task.status == .active && task.pendingMessage != nil {
                guard chat.canReviewConversationTasks, self.canSend() else { break }
                if task.initialSentAt == nil || task.evidence.last.map({ Date().timeIntervalSince($0.receivedAt) >= MessageConversationStore.settleDelay }) == true {
                    await self.send(task.id, ownerApproved: true)
                    break
                }
            }
            if chat.canReviewConversationTasks, let task = try self.store.claimReview() {
                await chat.reviewConversationTask(id: task.id)
            }
        } catch { self.error = error.localizedDescription }
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        guard self.canRead() else { return .failure(code: "PERMISSION_DENIED", message: "Messages Read is required.") }
        do {
            if command == "messages.conversation.review" {
                guard let paramsJSON, paramsJSON.utf8.count <= 32768,
                      var object = try JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any],
                      Set(object.keys).isSubset(of: ["taskID", "revision", "answersJSON", "followupMessage", "stopReason"]),
                      let answers = object.removeValue(forKey: "answersJSON") as? String,
                      let array = try JSONSerialization.jsonObject(with: Data(answers.utf8)) as? [[String: Any]] else {
                    throw MessageConversationStore.Failure.invalid("Expected taskID, revision, answersJSON and optional followupMessage or stopReason.")
                }
                object["operation"] = "review"
                object["answers"] = array
                return await self.handleNodeCommand("messages.conversation", paramsJSON: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), timeoutMilliseconds: timeoutMilliseconds)
            }
            if command == "messages.conversations" {
                if let paramsJSON {
                    guard paramsJSON.utf8.count <= 1024,
                          let parameters = try JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any], parameters.isEmpty else {
                        throw MessageConversationStore.Failure.invalid("messages.conversations takes no parameters.")
                    }
                }
                self.refresh()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(try self.store.list())
                guard data.count <= 262144 else { throw MessageConversationStore.Failure.invalid("Conversation history is too large. Review tasks in the main chat.") }
                return .success(payloadJSON: String(decoding: data, as: UTF8.self))
            }
            guard command == "messages.conversation", let paramsJSON, paramsJSON.utf8.count <= 32768,
                  let object = try JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any], let operation = object["operation"] as? String else {
                throw MessageConversationStore.Failure.invalid("Expected messages.conversation with an operation.")
            }
            switch operation {
            case "propose":
                guard Set(object.keys) == ["operation", "requestID", "recipient", "recipientName", "questions", "initialMessage"],
                      let requestID = object["requestID"] as? String, let recipient = object["recipient"] as? String,
                      let name = object["recipientName"] as? String, let questions = object["questions"] as? [String], let body = object["initialMessage"] as? String else {
                    throw MessageConversationStore.Failure.invalid("propose needs requestID, recipient, recipientName, questions (1–5 strings) and initialMessage.")
                }
                let task = try self.store.propose(requestID: requestID, recipient: recipient, name: name, questions: questions, initialMessage: body)
                if task.status == .proposed, self.automaticMessagingEnabled, self.isActive(), !self.isSending {
                    await self.approve(task.id, automatic: true)
                }
                self.refresh()
                let current = try self.store.list().first(where: { $0.id == task.id }) ?? task
                return .success(payloadJSON: String(decoding: try JSONSerialization.data(withJSONObject: ["taskID": task.id, "status": current.status.rawValue, "initialMessageSent": current.initialSentAt != nil, "nextStep": "This task is tracked inline in the main chat. With automatic messaging enabled, Operator starts and follows up automatically. If still proposed, enable messaging permissions and tap Start in its chat card. Report the actual status; never separately call sms.send or sms.compose for this task."]), as: UTF8.self))
            case "review":
                guard Set(object.keys).isSubset(of: ["operation", "taskID", "revision", "answers", "followupNeeded", "followupMessage", "stopReason"]),
                      let id = object["taskID"] as? String, let rawRevision = object["revision"],
                      let revision = JSONNumber.integer(rawRevision, in: 0...100000),
                      let rawAnswers = object["answers"] as? [[String: Any]], rawAnswers.count <= 5 else {
                    throw MessageConversationStore.Failure.invalid("review needs taskID, revision, answers and optional followupMessage or stopReason.")
                }
                let answers = try JSONDecoder().decode([ConversationAnswer].self, from: JSONSerialization.data(withJSONObject: rawAnswers))
                if object["stopReason"] != nil && !(object["stopReason"] is String) { throw MessageConversationStore.Failure.invalid("stopReason must be text.") }
                if object["followupMessage"] != nil && !(object["followupMessage"] is String) { throw MessageConversationStore.Failure.invalid("followupMessage must be text.") }
                try self.store.review(id, revision: revision, answers: answers, followupMessage: object["followupMessage"] as? String, stopReason: object["stopReason"] as? String)
            case "pause", "cancel", "resume":
                guard Set(object.keys) == ["operation", "taskID"], let id = object["taskID"] as? String else { throw MessageConversationStore.Failure.invalid("Control needs taskID only.") }
                // Resuming is an owner UI action: incoming replies cannot resume a task.
                guard operation != "resume" else { throw MessageConversationStore.Failure.invalid("The owner resumes tasks from the card in the main chat.") }
                try self.store.control(id, action: operation)
            default: throw MessageConversationStore.Failure.invalid("Use propose, review, pause or cancel.")
            }
            self.refresh()
            return .success(payloadJSON: "{\"saved\":true,\"nextStep\":\"Read messages.conversations for the resulting state. The native scheduler owns sends; never separately send a follow-up.\"}")
        } catch {
            return .failure(code: "CONVERSATION_REFUSED", message: error.localizedDescription)
        }
    }
}
