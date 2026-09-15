import Foundation
import OSLog

/// Whether a conversation with this JID already exists on the phone, so the
/// guard can be tested without the bridge.
protocol WhatsAppKnownRecipients: Sendable {
    func isKnown(jid: String) async throws -> Bool
}

/// Where the send history persists. UserDefaults: a relaunch must not reset
/// the daily count, or the cap would be a suggestion.
protocol WhatsAppSendHistoryStore: AnyObject, Sendable {
    func loadSendDates() -> [Date]
    func saveSendDates(_ dates: [Date])
}

final class UserDefaultsWhatsAppSendHistoryStore: WhatsAppSendHistoryStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "app.operator.whatsapp.sendDates"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func loadSendDates() -> [Date] { (self.defaults.array(forKey: self.key) as? [Double] ?? []).map(Date.init(timeIntervalSince1970:)) }
    func saveSendDates(_ dates: [Date]) { self.defaults.set(dates.map(\.timeIntervalSince1970), forKey: self.key) }
}

enum WhatsAppSendRefusal: Equatable, Sendable {
    /// The recipient is not in any existing chat. Operator never opens a
    /// conversation with someone new; that is the strongest spam signal.
    case unknownRecipient
    /// Too soon after the last send. Bursts are the second-strongest signal.
    case tooSoon(retryAfterSeconds: Int)
    /// The rolling 24-hour cap. A person does not send unattended messages
    /// all day; an account that does gets looked at.
    case dailyCapReached(resetsInSeconds: Int)

    var code: String {
        switch self {
        case .unknownRecipient: "RECIPIENT_UNKNOWN"
        case .tooSoon: "RATE_LIMITED"
        case .dailyCapReached: "DAILY_CAP_REACHED"
        }
    }

    var message: String {
        switch self {
        case .unknownRecipient:
            "Operator only messages people who are already in your WhatsApp chats. It will not start a conversation with someone new; that is what gets accounts banned."
        case let .tooSoon(seconds):
            "Operator sends at most one WhatsApp message every \(WhatsAppSendGuard.minimumGapSeconds) seconds to keep your account safe. Try again in \(seconds) seconds."
        case let .dailyCapReached(seconds):
            "Operator has sent \(WhatsAppSendGuard.dailyCap) WhatsApp messages in the last 24 hours, its limit for keeping your account safe. The limit resets in \(seconds / 60) minutes."
        }
    }
}

/// The parts of "look like a person on WhatsApp Web, not a bot" that can be
/// enforced in code. The acknowledgement the owner accepts before turning
/// WhatsApp sending on names exactly these three, so what it promises is
/// what this checks.
@MainActor
final class WhatsAppSendGuard {
    nonisolated static let minimumGapSeconds = 20
    nonisolated static let dailyCap = 20

    private let recipients: any WhatsAppKnownRecipients
    private let history: any WhatsAppSendHistoryStore
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "whatsapp-guard")

    init(recipients: any WhatsAppKnownRecipients, history: any WhatsAppSendHistoryStore, now: @escaping () -> Date = Date.init) {
        self.recipients = recipients
        self.history = history
        self.now = now
    }

    /// Nil means the send may proceed. Order matters: the recipient check is
    /// first so a refused stranger never counts against the pace.
    func check(recipientJID: String) async -> WhatsAppSendRefusal? {
        // A lookup that fails counts as unknown: the guard fails closed.
        let known = (try? await self.recipients.isKnown(jid: recipientJID)) ?? false
        guard known else {
            self.logger.info("[whatsapp-guard] refused branch=unknown-recipient")
            return .unknownRecipient
        }
        let current = self.now()
        let recent = self.history.loadSendDates().filter { current.timeIntervalSince($0) < 86_400 }
        if let last = recent.max() {
            let elapsed = current.timeIntervalSince(last)
            if elapsed < Double(Self.minimumGapSeconds) {
                self.logger.info("[whatsapp-guard] refused branch=too-soon")
                return .tooSoon(retryAfterSeconds: Int((Double(Self.minimumGapSeconds) - elapsed).rounded(.up)))
            }
        }
        if recent.count >= Self.dailyCap, let oldest = recent.min() {
            self.logger.info("[whatsapp-guard] refused branch=daily-cap")
            return .dailyCapReached(resetsInSeconds: Int((86_400 - current.timeIntervalSince(oldest)).rounded(.up)))
        }
        return nil
    }

    /// Called only after the bridge reports the send went out.
    func recordSend() {
        let current = self.now()
        var recent = self.history.loadSendDates().filter { current.timeIntervalSince($0) < 86_400 }
        recent.append(current)
        self.history.saveSendDates(recent)
    }

    var sendsInLast24Hours: Int {
        let current = self.now()
        return self.history.loadSendDates().filter { current.timeIntervalSince($0) < 86_400 }.count
    }
}

extension NativeWhatsAppReadClient: WhatsAppKnownRecipients {
    /// Known means the local store holds at least one message in a chat with
    /// this JID - a person or group the owner has actually exchanged messages
    /// with. Asking for the chat list instead was wrong twice over: the bridge
    /// caps that call at 50, so the first device attempt threw and refused
    /// everyone, and a recency-ordered list would refuse anyone quiet lately.
    func isKnown(jid: String) async throws -> Bool {
        !(try self.messages(chat: jid, limit: 1)).isEmpty
    }
}
