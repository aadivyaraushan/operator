import Foundation

/// One text the owner received, as the Shortcuts automation reported it.
/// Sender is whatever Shortcuts passed: a contact's name when it knows one,
/// otherwise the number or address.
struct IncomingMessage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sender: String
    let text: String
    let receivedAt: Date
    enum Direction: String, Codable, Sendable { case received, sent }
    let direction: Direction

    init(id: String, sender: String, text: String, receivedAt: Date, direction: Direction = .received) {
        self.id = id; self.sender = sender; self.text = text
        self.receivedAt = receivedAt; self.direction = direction
    }

    private enum CodingKeys: String, CodingKey { case id, sender, text, receivedAt, direction }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.sender = try values.decode(String.self, forKey: .sender)
        self.text = try values.decode(String.self, forKey: .text)
        self.receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        self.direction = try values.decodeIfPresent(Direction.self, forKey: .direction) ?? .received
    }
}

/// The feed of incoming texts, newest first, in one JSON file in
/// Application Support. Bounded in count and age: this is what was said
/// lately, not an archive, and iOS gives the app nothing older anyway.
///
/// Written by the app intent, which Shortcuts may run while the phone is
/// locked, so the file is protected only until first unlock. Read by the
/// `messages.incoming` command.
final class IncomingMessageStore: @unchecked Sendable {
    static let countLimit = 500
    static let ageLimit: TimeInterval = 14 * 24 * 3600
    /// The same message reported twice inside this window is one message.
    static let duplicateWindow: TimeInterval = 120

    private let fileURL: URL
    private let now: () -> Date
    private static let queue = DispatchQueue(label: "app.operator.ios.incoming-messages")

    init(supportDirectory: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = supportDirectory.appendingPathComponent("Operator/incoming-messages.json")
        self.now = now
    }

    /// Records one message and returns it, or nil when it duplicates one
    /// already recorded (Shortcuts can run an automation twice for one text).
    @discardableResult
    func record(sender: String, text: String, direction: IncomingMessage.Direction = .received) -> IncomingMessage? {
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Self.queue.sync {
            let current = self.now()
            var messages = self.prune(self.load(), at: current)
            if direction == .received && messages.contains(where: {
                $0.direction == direction && $0.sender == sender && $0.text == text && current.timeIntervalSince($0.receivedAt) < Self.duplicateWindow
            }) {
                return nil
            }
            let message = IncomingMessage(id: UUID().uuidString, sender: sender, text: text, receivedAt: current, direction: direction)
            messages.insert(message, at: 0)
            self.save(Array(messages.prefix(Self.countLimit)))
            return message
        }
    }

    /// Newest first; only messages after `since` when given.
    func messages(since: Date? = nil, limit: Int) -> [IncomingMessage] {
        Self.queue.sync {
            let kept = self.prune(self.load(), at: self.now())
            let filtered = since.map { since in kept.filter { $0.receivedAt > since } } ?? kept
            return Array(filtered.prefix(max(0, limit)))
        }
    }

    /// Only received texts prove that the incoming automation is working.
    func status() -> (count: Int, last: IncomingMessage?) {
        Self.queue.sync {
            let received = self.prune(self.load(), at: self.now()).filter { $0.direction == .received }
            return (received.count, received.first)
        }
    }

    var count: Int { Self.queue.sync { self.prune(self.load(), at: self.now()).count } }

    private func prune(_ messages: [IncomingMessage], at current: Date) -> [IncomingMessage] {
        messages.filter { current.timeIntervalSince($0.receivedAt) < Self.ageLimit }
    }

    private func load() -> [IncomingMessage] {
        guard let data = try? Data(contentsOf: self.fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([IncomingMessage].self, from: data)) ?? []
    }

    private func save(_ messages: [IncomingMessage]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(messages) else { return }
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The store the intent and the app share: one file under the app's
    /// Application Support, wherever iOS put the container this launch.
    static func standard() -> IncomingMessageStore {
        IncomingMessageStore(supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
}
