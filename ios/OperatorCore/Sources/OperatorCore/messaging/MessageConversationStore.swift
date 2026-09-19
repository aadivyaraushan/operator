import Foundation

public struct ConversationQuestion: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    public var answer: String?
    public var evidenceMessageID: String?
    public var remainingQuestion: String?
}

public struct ConversationEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sender: String
    public let text: String
    public let receivedAt: Date
    public init(id: String, sender: String, text: String, receivedAt: Date) {
        self.id = id; self.sender = sender; self.text = text; self.receivedAt = receivedAt
    }
}

public struct ConversationAnswer: Codable, Sendable {
    public let questionID: String
    public let messageID: String
    public let quote: String
    public let answer: String
    public let remainingQuestion: String?
    public init(questionID: String, messageID: String, quote: String, answer: String, remainingQuestion: String? = nil) {
        self.questionID = questionID; self.messageID = messageID; self.quote = quote; self.answer = answer; self.remainingQuestion = remainingQuestion
    }
}

public struct MessageConversation: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case proposed, active, paused, completed, cancelled, expired, needsAttention }
    public enum SendState: String, Codable, Sendable { case idle, sending, unknown }
    public let id: String
    public let requestID: String
    public let recipient: String
    public let recipientName: String
    public let initialMessage: String
    public let createdAt: Date
    public let expiresAt: Date
    public var questions: [ConversationQuestion]
    public var status: Status = .proposed
    public var automaticFollowups = false
    public var evidence: [ConversationEvidence] = []
    public var revision = 0
    public var reviewedRevision = -1
    public var reviewLeaseUntil: Date?
    public var reviewAttempts = 0
    public var sendStartedAt: Date?
    public var initialSentAt: Date?
    public var lastSendAt: Date?
    public var followupCount = 0
    public var pendingMessage: String?
    public var lastFollowupMessage: String?
    public var followupMessages: [String]?
    public var sendState: SendState = .idle
    public var note: String?

    public var outstanding: [ConversationQuestion] { self.questions.filter { $0.answer == nil || $0.remainingQuestion != nil } }
}

public struct ConversationSendReservation: Sendable {
    public let taskID: String
    public let recipient: String
    public let body: String
}

/// Durable, bounded tasks. All instances serialize the read-modify-write cycle,
/// including the Shortcuts intent and foreground services in the same process.
public final class MessageConversationStore: @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? { switch self { case let .invalid(message): message } }
    }
    public enum SendOutcome: Sendable { case sent, failed, unknown }
    public static let settleDelay: TimeInterval = 60
    private static let lock = NSLock()
    private let url: URL
    private let now: @Sendable () -> Date

    public init(supportDirectory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = supportDirectory.appendingPathComponent("Operator/message-conversations.json")
        self.now = now
    }

    public static func standard() -> MessageConversationStore {
        MessageConversationStore(supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Handles only: never fuzzy-match contact names or phone suffixes.
    public static func normalizedHandle(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("@"), !value.contains(where: { $0.isWhitespace }), value.count <= 254 { return value }
        let phone = value.filter { !" ()-.".contains($0) }
        guard phone.hasPrefix("+"), (8...16).contains(phone.count), phone.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return phone
    }

    private func transaction<T>(_ body: (inout [MessageConversation]) throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var tasks: [MessageConversation] = []
        if FileManager.default.fileExists(atPath: self.url.path) {
            tasks = try JSONDecoder().decode([MessageConversation].self, from: Data(contentsOf: self.url))
        }
        let original = tasks
        for i in tasks.indices where [.proposed, .active, .paused].contains(tasks[i].status) && tasks[i].expiresAt <= self.now() {
            tasks[i].status = .expired
            tasks[i].pendingMessage = nil
            tasks[i].revision += 1
        }
        let result = try body(&tasks)
        guard tasks != original else { return result }
        let data = try JSONEncoder().encode(tasks)
        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return result
    }

    public func list() throws -> [MessageConversation] { try self.transaction { $0 } }

    @discardableResult
    public func propose(requestID: String, recipient: String, name: String, questions: [String], initialMessage: String) throws -> MessageConversation {
        guard !requestID.isEmpty, requestID.count <= 100, let handle = Self.normalizedHandle(recipient),
              !name.isEmpty, name.count <= 100, (1...5).contains(questions.count),
              questions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 300 }),
              Set(questions).count == questions.count, !initialMessage.isEmpty, initialMessage.count <= 2000 else {
            throw Failure.invalid("Use a resolved international phone number or email, 1–5 distinct questions and a nonempty initial message.")
        }
        return try self.transaction { tasks in
            if let previous = tasks.first(where: { $0.requestID == requestID }) {
                guard previous.recipient == handle, previous.initialMessage == initialMessage, previous.questions.map(\.question) == questions else {
                    throw Failure.invalid("This request ID already belongs to a different conversation.")
                }
                return previous
            }
            guard !tasks.contains(where: { $0.recipient == handle && [.proposed, .active, .paused, .needsAttention].contains($0.status) }) else {
                throw Failure.invalid("A conversation with this recipient already exists. Resume or cancel it first.")
            }
            tasks.removeAll { [.completed, .cancelled, .expired].contains($0.status) && self.now().timeIntervalSince($0.createdAt) > 14 * 86400 }
            guard tasks.count < 50, tasks.filter({ [.proposed, .active].contains($0.status) }).count < 5 else { throw Failure.invalid("Conversation task limit reached.") }
            let task = MessageConversation(id: UUID().uuidString, requestID: requestID, recipient: handle, recipientName: name,
                initialMessage: initialMessage, createdAt: self.now(), expiresAt: self.now().addingTimeInterval(86400),
                questions: questions.map { ConversationQuestion(id: UUID().uuidString, question: $0) })
            tasks.insert(task, at: 0)
            return task
        }
    }

    private func change(_ id: String, _ body: (inout MessageConversation) throws -> Void) throws {
        try self.transaction { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("Unknown conversation.") }
            try body(&tasks[i])
        }
    }

    /// The native service activates an owner-requested task only after checking send permissions.
    public func approve(_ id: String, automaticFollowups: Bool) throws {
        try self.change(id) { task in
            guard task.status == .proposed else { throw Failure.invalid("This proposal is no longer available.") }
            task.status = .active
            task.automaticFollowups = automaticFollowups
            task.pendingMessage = task.initialMessage
            task.revision += 1
        }
    }

    public func control(_ id: String, action: String) throws {
        try self.change(id) { task in
            guard ![.completed, .cancelled, .expired].contains(task.status) else { throw Failure.invalid("This task has ended.") }
            switch action {
            case "cancel": task.status = .cancelled
            case "pause": task.status = .paused
            case "resume":
                guard task.status == .paused, task.sendState == .idle else { throw Failure.invalid("An uncertain send cannot be resumed. Check Messages and start a new task if needed.") }
                task.status = .active
            default: throw Failure.invalid("Unknown conversation control.")
            }
            if action != "resume" { task.pendingMessage = nil }
            if action == "resume", task.initialSentAt == nil { task.pendingMessage = task.initialMessage }
            task.revision += 1
            task.reviewLeaseUntil = nil
        }
    }

    /// Returns changed IDs for a privacy-preserving local notification.
    public func receive(_ message: ConversationEvidence) throws -> [String] {
        guard let handle = Self.normalizedHandle(message.sender) else { return [] }
        return try self.transaction { tasks in
            var changed: [String] = []
            for i in tasks.indices {
                guard [.active, .paused].contains(tasks[i].status), tasks[i].recipient == handle,
                      let sentAt = tasks[i].initialSentAt ?? (tasks[i].sendState == .sending ? tasks[i].sendStartedAt : nil), message.receivedAt >= sentAt,
                      message.receivedAt <= self.now().addingTimeInterval(60),
                      !tasks[i].evidence.contains(where: { $0.id == message.id }) else { continue }
                guard tasks[i].evidence.count < 100 else {
                    tasks[i].status = .needsAttention; tasks[i].note = "Too many replies. Review this conversation yourself."; continue
                }
                guard message.text.utf8.count <= 16000 else {
                    tasks[i].status = .needsAttention; tasks[i].note = "A reply is too large to review automatically."; continue
                }
                tasks[i].evidence.append(message)
                tasks[i].evidence.sort { $0.receivedAt < $1.receivedAt }
                tasks[i].pendingMessage = nil // A new reply invalidates any unsent follow-up.
                tasks[i].revision += 1
                tasks[i].reviewLeaseUntil = nil
                tasks[i].reviewAttempts = 0
                changed.append(tasks[i].id)
            }
            return changed
        }
    }

    public func claimReview() throws -> MessageConversation? {
        try self.transaction { tasks in
            for i in tasks.indices where tasks[i].status == .active && tasks[i].reviewAttempts >= 3 && (tasks[i].reviewLeaseUntil ?? .distantPast) <= self.now() {
                tasks[i].status = .needsAttention
                tasks[i].note = "The reply could not be reviewed after three attempts. Check this conversation yourself."
            }
            guard let i = tasks.firstIndex(where: { task in
                task.status == .active && task.sendState == .idle && task.initialSentAt != nil &&
                task.reviewedRevision != task.revision &&
                (task.reviewLeaseUntil == nil || task.reviewLeaseUntil! <= self.now()) &&
                task.evidence.last.map { self.now().timeIntervalSince($0.receivedAt) >= Self.settleDelay } == true
            }) else { return nil }
            tasks[i].reviewLeaseUntil = self.now().addingTimeInterval(300)
            tasks[i].reviewAttempts += 1
            return tasks[i]
        }
    }

    /// The agent evaluates progress and optionally writes its own next reply.
    public func review(_ id: String, revision: Int, answers: [ConversationAnswer], followupMessage: String? = nil, stopReason: String? = nil) throws {
        try self.change(id) { task in
            guard task.status == .active, task.sendState == .idle, task.revision == revision,
                  task.reviewedRevision != revision else { throw Failure.invalid("Stale review. Read the conversation again.") }
            guard Set(answers.map(\.questionID)).count == answers.count else { throw Failure.invalid("Duplicate answers.") }
            for answer in answers {
                guard let i = task.questions.firstIndex(where: { $0.id == answer.questionID }),
                      let message = task.evidence.first(where: { $0.id == answer.messageID }),
                      !answer.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      message.text.contains(answer.quote), !answer.answer.isEmpty, answer.answer.count <= 1000 else {
                    throw Failure.invalid("Every answer requires a real matching reply and an exact supporting quotation.")
                }
                let remaining = answer.remainingQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let remaining {
                    guard !remaining.isEmpty, remaining.count <= 300 else { throw Failure.invalid("A partial answer needs a short question asking only for the missing detail.") }
                }
                task.questions[i].remainingQuestion = remaining
                task.questions[i].answer = answer.answer
                task.questions[i].evidenceMessageID = answer.messageID
            }
            task.reviewAttempts = 0
            task.reviewedRevision = revision
            task.reviewLeaseUntil = nil
            task.pendingMessage = nil
            if let stopReason {
                task.status = .needsAttention; task.note = String(stopReason.prefix(300))
            } else if task.outstanding.isEmpty {
                task.status = .completed; task.note = "All questions have answers."
            } else if let message = followupMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                      task.evidence.contains(where: { $0.receivedAt >= (task.lastSendAt ?? task.createdAt) }) {
                guard !message.isEmpty, message.count <= 2000 else { throw Failure.invalid("The reply must contain 1–2000 characters.") }
                if message != task.lastFollowupMessage {
                    task.pendingMessage = message
                } else {
                    task.note = "Waiting for more information; this reply was already sent."
                }
            }
        }
    }

    /// Retire drafts created by the old template-based follow-up loop.
    public func migrateToAgentReplies() throws {
        try self.transaction { tasks in
            for i in tasks.indices {
                let legacyDraft = tasks[i].pendingMessage?.hasPrefix("Following up on the remaining question") == true
                let legacyLimit = tasks[i].status == .needsAttention && tasks[i].note == "Follow-up limit reached; some questions are unanswered."
                guard tasks[i].sendState == .idle, legacyDraft || legacyLimit else { continue }
                tasks[i].pendingMessage = nil
                if legacyLimit { tasks[i].status = .active }
                tasks[i].note = nil
                tasks[i].reviewedRevision = -1
                tasks[i].reviewLeaseUntil = nil
                tasks[i].reviewAttempts = 0
            }
        }
    }

    public func reserveSend(_ id: String, ownerApproved: Bool = false) throws -> ConversationSendReservation {
        try self.transaction { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("Unknown conversation.") }
            let task = tasks[i]
            guard task.status == .active, task.sendState == .idle, let body = task.pendingMessage else { throw Failure.invalid("Nothing ready to send.") }
            if task.initialSentAt != nil {
                guard ownerApproved || task.automaticFollowups else { throw Failure.invalid("Waiting for automatic messaging permission.") }
                guard task.evidence.last.map({ self.now().timeIntervalSince($0.receivedAt) >= Self.settleDelay }) == true else { throw Failure.invalid("Waiting for the incoming reply to finish.") }
            }
            tasks[i].sendStartedAt = self.now()
            tasks[i].sendState = .sending // Persist before opening Shortcuts; never automatically replay this state.
            return ConversationSendReservation(taskID: id, recipient: task.recipient, body: body)
        }
    }

    public func finishSend(_ id: String, outcome: SendOutcome) throws {
        try self.change(id) { task in
            guard task.sendState == .sending else { throw Failure.invalid("No reserved send.") }
            switch outcome {
            case .sent:
                if task.initialSentAt == nil { task.initialSentAt = task.sendStartedAt ?? self.now() } else { task.followupCount += 1; task.lastFollowupMessage = task.pendingMessage; if let message = task.pendingMessage { task.followupMessages = (task.followupMessages ?? []) + [message] } }
                task.lastSendAt = self.now(); task.sendState = .idle; task.pendingMessage = nil
            case .failed:
                task.sendState = .idle; task.pendingMessage = nil
                if task.status != .cancelled { task.status = .needsAttention }
                task.note = "The send failed or was cancelled. Nothing will be retried automatically."
            case .unknown:
                task.sendState = .unknown; task.pendingMessage = nil
                if task.status != .cancelled { task.status = .needsAttention }
                task.note = "Send outcome unknown. Check Messages; Operator will not resend."
            }
        }
    }

    /// Called once on foreground service creation, not by the background intent.
    public func recoverInterruptedSends() throws {
        try self.transaction { tasks in
            for i in tasks.indices where tasks[i].sendState == .sending {
                tasks[i].sendState = .unknown; tasks[i].pendingMessage = nil
                if tasks[i].status != .cancelled { tasks[i].status = .needsAttention }
                tasks[i].note = "Operator stopped during a send. Check Messages; it will not resend."
            }
        }
    }
}
