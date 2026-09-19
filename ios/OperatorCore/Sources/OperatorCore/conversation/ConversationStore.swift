import Foundation
import OSLog

public actor ConversationStore {
    private let fileURL: URL
    private let logger = Logger(subsystem: "app.operator.ios", category: "conversation-store")
    private var cached: ConversationSnapshot?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> ConversationSnapshot {
        if let cached {
            return cached
        }
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            let empty = ConversationSnapshot()
            self.cached = empty
            self.logger.info("[conversation] loaded empty store")
            return empty
        }

        let data = try Data(contentsOf: self.fileURL)
        var snapshot = try Self.decoder.decode(ConversationSnapshot.self, from: data)
        let recoveredSendingIDs = Set(snapshot.outbox.filter { $0.state == .sending }.map(\.messageID))
        if !recoveredSendingIDs.isEmpty {
            for index in snapshot.outbox.indices where snapshot.outbox[index].state == .sending {
                snapshot.outbox[index].state = .waiting
            }
            for index in snapshot.messages.indices where recoveredSendingIDs.contains(snapshot.messages[index].id) {
                snapshot.messages[index].delivery = .waiting
            }
            try self.persist(snapshot)
            self.logger.notice("[conversation] recovered interrupted sends count=\(recoveredSendingIDs.count)")
        }
        self.cached = snapshot
        self.logger.info(
            "[conversation] loaded messages=\(snapshot.messages.count) outbox=\(snapshot.outbox.count)")
        return snapshot
    }

    @discardableResult
    public func updateDraft(_ draft: String) throws -> ConversationSnapshot {
        var snapshot = try self.load()
        snapshot.draft = draft
        try self.save(snapshot)
        return snapshot
    }

    @discardableResult
    public func stageUserMessage(
        id messageID: UUID = UUID(),
        text: String,
        now: Date = Date()) throws -> ConversationSnapshot
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try self.load()
        }
        var snapshot = try self.load()
        let message = ChatMessage(
            id: messageID,
            role: .user,
            text: trimmed,
            createdAt: now,
            delivery: .waiting)
        let entry = OutboxEntry(
            id: messageID,
            messageID: messageID,
            text: trimmed,
            idempotencyKey: messageID.uuidString.lowercased(),
            state: .waiting)
        snapshot.messages.append(message)
        snapshot.outbox.append(entry)
        snapshot.draft = ""
        try self.save(snapshot)
        self.logger.info("[conversation] staged user message id=\(messageID.uuidString, privacy: .public)")
        return snapshot
    }

    @discardableResult
    public func markSending(entryID: UUID) throws -> ConversationSnapshot {
        var snapshot = try self.load()
        guard let outboxIndex = snapshot.outbox.firstIndex(where: { $0.id == entryID }) else {
            return snapshot
        }
        snapshot.outbox[outboxIndex].state = .sending
        self.setDelivery(.sending, messageID: snapshot.outbox[outboxIndex].messageID, in: &snapshot)
        try self.save(snapshot)
        return snapshot
    }

    @discardableResult
    public func markWaiting(entryID: UUID) throws -> ConversationSnapshot {
        var snapshot = try self.load()
        guard let outboxIndex = snapshot.outbox.firstIndex(where: { $0.id == entryID }) else {
            return snapshot
        }
        snapshot.outbox[outboxIndex].state = .waiting
        self.setDelivery(.waiting, messageID: snapshot.outbox[outboxIndex].messageID, in: &snapshot)
        try self.save(snapshot)
        self.logger.info("[conversation] returned interrupted send to queue id=\(entryID.uuidString, privacy: .public)")
        return snapshot
    }

    @discardableResult
    public func markAccepted(entryID: UUID) throws -> ConversationSnapshot {
        var snapshot = try self.load()
        guard let entry = snapshot.outbox.first(where: { $0.id == entryID }) else {
            return snapshot
        }
        snapshot.outbox.removeAll { $0.id == entryID }
        self.setDelivery(.accepted, messageID: entry.messageID, in: &snapshot)
        try self.save(snapshot)
        self.logger.info("[conversation] gateway accepted message id=\(entry.messageID.uuidString, privacy: .public)")
        return snapshot
    }

    @discardableResult
    public func markFailed(entryID: UUID) throws -> ConversationSnapshot {
        var snapshot = try self.load()
        guard let outboxIndex = snapshot.outbox.firstIndex(where: { $0.id == entryID }) else {
            return snapshot
        }
        snapshot.outbox[outboxIndex].state = .failed
        self.setDelivery(.failed, messageID: snapshot.outbox[outboxIndex].messageID, in: &snapshot)
        try self.save(snapshot)
        return snapshot
    }

    @discardableResult
    public func appendAssistant(text: String, now: Date = Date()) throws -> ConversationSnapshot {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try self.load()
        }
        var snapshot = try self.load()
        snapshot.messages.append(ChatMessage(
            role: .assistant,
            text: trimmed,
            createdAt: now))
        try self.save(snapshot)
        self.logger.info("[conversation] appended assistant reply")
        return snapshot
    }

    @discardableResult
    public func appendWeatherCard(_ card: WeatherCard, now: Date = Date()) throws -> ConversationSnapshot {
        var snapshot = try self.load()
        snapshot.messages.append(ChatMessage(role: .system, text: "Weather forecast", createdAt: now, attachment: .weather(card)))
        try self.save(snapshot)
        self.logger.info("[conversation] appended weather card")
        return snapshot
    }

    private func setDelivery(
        _ delivery: MessageDelivery,
        messageID: UUID,
        in snapshot: inout ConversationSnapshot)
    {
        guard let messageIndex = snapshot.messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        snapshot.messages[messageIndex].delivery = delivery
    }

    private func save(_ snapshot: ConversationSnapshot) throws {
        try self.persist(snapshot)
        self.cached = snapshot
    }

    private func persist(_ snapshot: ConversationSnapshot) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: self.fileURL, options: [.atomic])
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: self.fileURL.path)
        #endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
