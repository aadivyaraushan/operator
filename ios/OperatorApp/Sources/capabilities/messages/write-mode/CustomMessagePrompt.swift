import Foundation
import OSLog

/// Asks the person to write a text themselves, and hands their words back to
/// the send that is waiting on them. One request at a time.
@MainActor
final class CustomMessagePrompt: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id: UUID
        let recipients: [String]
    }

    /// The card the chat is showing, if any.
    @Published private(set) var pending: Request?

    private var waiting: CheckedContinuation<String?, Never>?
    private let logger = Logger(subsystem: "app.operator.ios", category: "message-send")

    /// The person's words, trimmed, or nil when they chose not to send.
    func write(to recipients: [String]) async -> String? {
        guard self.pending == nil else {
            self.logger.info("[message-send] custom message asked for while another is open")
            return nil
        }
        self.logger.info("[message-send] asking the person to write recipients=\(recipients.count)")
        return await withCheckedContinuation { continuation in
            self.waiting = continuation
            self.pending = Request(id: UUID(), recipients: recipients)
        }
    }

    func submit(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.utf8.count <= 4_000 else { return }
        self.logger.info("[message-send] person wrote their message bytes=\(words.utf8.count)")
        self.finish(words)
    }

    func decline() {
        self.logger.info("[message-send] person chose not to send")
        self.finish(nil)
    }

    private func finish(_ words: String?) {
        guard let waiting = self.waiting else { return }
        self.waiting = nil
        self.pending = nil
        waiting.resume(returning: words)
    }
}
