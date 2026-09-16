import Foundation
import OSLog

/// A WhatsApp message waiting for the owner's tap on a notification.
struct PendingSend: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let recipientJID: String
    let recipientName: String
    let body: String
    let createdAt: Date
}

/// Drafts awaiting a tap, in one JSON file: the tap can arrive after the
/// process was suspended or relaunched, so they cannot live in memory.
/// One per recipient; a newer draft to the same person replaces the older.
final class PendingSendStore: @unchecked Sendable {
    static let expiry: TimeInterval = 10 * 60

    private let fileURL: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "app.operator.ios.pending-sends")

    init(supportDirectory: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = supportDirectory.appendingPathComponent("Operator/pending-sends.json")
        self.now = now
    }

    /// Adds the draft; returns the id of the draft to the same recipient it
    /// replaced, if any, so its notification can be withdrawn.
    func add(_ send: PendingSend) -> String? {
        self.queue.sync {
            var all = self.prune(self.load())
            let replaced = all.first { $0.recipientJID == send.recipientJID }?.id
            all.removeAll { $0.recipientJID == send.recipientJID }
            all.append(send)
            self.save(all)
            return replaced
        }
    }

    /// The live draft with this id, or nil when unknown or expired.
    func take(id: String) -> PendingSend? {
        self.queue.sync {
            var all = self.prune(self.load())
            guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
            let send = all.remove(at: index)
            self.save(all)
            return send
        }
    }

    func remove(id: String) {
        self.queue.sync {
            let all = self.prune(self.load()).filter { $0.id != id }
            self.save(all)
        }
    }

    var count: Int { self.queue.sync { self.prune(self.load()).count } }

    private func prune(_ sends: [PendingSend]) -> [PendingSend] {
        sends.filter { self.now().timeIntervalSince($0.createdAt) < Self.expiry }
    }

    private func load() -> [PendingSend] {
        guard let data = try? Data(contentsOf: self.fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PendingSend].self, from: data)) ?? []
    }

    private func save(_ sends: [PendingSend]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sends) else { return }
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The notifications the center posts, behind a protocol for the tests.
@MainActor
protocol SendConfirmationNotifying: AnyObject {
    /// The question, with Send and Don't send actions carrying `id`.
    func askToConfirm(id: String, recipientName: String, body: String)
    func withdraw(id: String)
    /// What happened after a tap.
    func report(title: String, body: String)
}

/// Asks the owner to confirm a WhatsApp send by notification and performs
/// it on their tap. Guarded twice: before the question is posted, so a
/// refused send never becomes a notification, and again at the tap, since
/// minutes may have passed.
@MainActor
final class PendingSendCenter {
    enum AskOutcome: Equatable, Sendable {
        case asked(id: String)
        case refused(WhatsAppSendRefusal)
    }

    enum PerformOutcome: Equatable, Sendable {
        case sent(recipientName: String)
        case expired
        case refused(WhatsAppSendRefusal)
        case failed
    }

    static let sendTimeoutMilliseconds = 20_000

    private let store: PendingSendStore
    private let notifier: any SendConfirmationNotifying
    private let sender: any WhatsAppTextSending
    private let guardrail: WhatsAppSendGuard?
    private let recordSent: @MainActor (PendingSend) async -> Void
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "pending-send")

    init(
        store: PendingSendStore,
        notifier: any SendConfirmationNotifying,
        sender: any WhatsAppTextSending,
        guardrail: WhatsAppSendGuard?,
        recordSent: @escaping @MainActor (PendingSend) async -> Void,
        now: @escaping () -> Date = Date.init)
    {
        self.store = store
        self.notifier = notifier
        self.sender = sender
        self.guardrail = guardrail
        self.recordSent = recordSent
        self.now = now
    }

    func ask(_ request: WhatsAppComposeRequest, recipientName: String) async -> AskOutcome {
        if let guardrail, let refusal = await guardrail.check(recipientJID: request.recipientJID) {
            self.logger.info("[pending-send] refused before asking code=\(refusal.code, privacy: .public)")
            return .refused(refusal)
        }
        let send = PendingSend(id: UUID().uuidString, recipientJID: request.recipientJID, recipientName: recipientName, body: request.body, createdAt: self.now())
        if let replaced = self.store.add(send) { self.notifier.withdraw(id: replaced) }
        self.notifier.askToConfirm(id: send.id, recipientName: recipientName, body: request.body)
        self.logger.info("[pending-send] asked bodyBytes=\(request.body.utf8.count)")
        return .asked(id: send.id)
    }

    /// The Send action. The draft is taken out of the store first, so a
    /// second tap on the same notification sends nothing.
    func perform(id: String) async -> PerformOutcome {
        self.notifier.withdraw(id: id)
        guard let send = self.store.take(id: id) else {
            self.logger.info("[pending-send] tap on an expired or unknown draft")
            self.notifier.report(title: "Not sent", body: "That confirmation expired. Ask Operator again.")
            return .expired
        }
        if let guardrail, let refusal = await guardrail.check(recipientJID: send.recipientJID) {
            self.logger.info("[pending-send] refused at the tap code=\(refusal.code, privacy: .public)")
            self.notifier.report(title: "Not sent to \(send.recipientName)", body: refusal.message)
            return .refused(refusal)
        }
        do {
            _ = try await self.sender.send(.init(recipientJID: send.recipientJID, body: send.body), timeoutMilliseconds: Self.sendTimeoutMilliseconds)
            self.guardrail?.recordSend()
            await self.recordSent(send)
            self.notifier.report(title: "Sent to \(send.recipientName)", body: send.body)
            self.logger.info("[pending-send] sent")
            return .sent(recipientName: send.recipientName)
        } catch {
            self.logger.error("[pending-send] send failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            self.notifier.report(title: "Couldn't send to \(send.recipientName)", body: "WhatsApp did not accept the message. Open Operator and try again.")
            return .failed
        }
    }

    /// The Don't send action, or the notification dismissed.
    func decline(id: String) {
        self.store.remove(id: id)
        self.notifier.withdraw(id: id)
        self.logger.info("[pending-send] declined")
    }
}
