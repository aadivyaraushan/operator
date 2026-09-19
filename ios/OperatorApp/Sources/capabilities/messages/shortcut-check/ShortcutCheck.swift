import Foundation

/// The two shortcuts Messages depends on, each installed by the owner.
enum MessageShortcut: String, CaseIterable, Codable, Sendable {
    /// OperatorSendMessage: sends a text with no confirmation tap.
    case send
    /// OperatorRecordMessage: what the "When I get a message" automation runs.
    case record
}

/// What is known about a shortcut. iOS cannot be asked whether one is
/// installed, so the only way out of `notChecked` is a test run.
enum ShortcutInstallStatus: Equatable, Codable, Sendable {
    case notChecked
    case installed(checkedAt: Date)
    /// Shortcuts never answered, which is what a missing shortcut looks like.
    case notFound
    /// Shortcuts answered, but not with proof. Carries its own words.
    case problem(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

enum ShortcutCheck {
    /// Handed to the record shortcut in place of a text. Operator's action
    /// sees it, notes that it ran, and files nothing.
    static let recordMarker = "operator-shortcut-check-4f1c"

    /// Whether a run of the record action is a check rather than a text. A
    /// shortcut that takes its text from its own message trigger receives
    /// none when Operator runs it, so a run with no text is a check as well.
    static func isCheckRun(text: String?) -> Bool {
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == self.recordMarker
    }

    /// The send shortcut's test input: no recipient and no body, so there is
    /// nothing for Send Message to send.
    @MainActor
    static func testRunURL(for shortcut: MessageShortcut, recordShortcutName: String) -> URL? {
        switch shortcut {
        case .send:
            guard let data = try? JSONSerialization.data(withJSONObject: ["check": true, "to": "", "body": ""], options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return ForegroundMessageSendService.runURL(shortcutName: ForegroundMessageSendService.shortcutName, text: text)
        case .record:
            return ForegroundMessageSendService.runURL(shortcutName: recordShortcutName, text: self.recordMarker)
        }
    }

    /// - Parameter recordActionRan: Operator's own action ran during this
    ///   check. For the record shortcut that is the proof; what Shortcuts
    ///   reports is only used to explain a failure.
    @MainActor
    static func status(
        of shortcut: MessageShortcut,
        completion: ShortcutSendCoordinator.Completion,
        recordActionRan: Bool,
        now: Date
    ) -> ShortcutInstallStatus {
        if shortcut == .record, recordActionRan { return .installed(checkedAt: now) }
        switch completion.outcome {
        case .timedOut:
            return .notFound
        case .couldNotOpen:
            return .problem("The Shortcuts app could not be opened.")
        case .error:
            // The send shortcut run with no recipient gets as far as Send
            // Message, which then fails - proof it is there. Only an error
            // about the shortcut itself means it is not.
            if shortcut == .send, let message = completion.message,
               !message.localizedCaseInsensitiveContains(ForegroundMessageSendService.shortcutName) {
                return .installed(checkedAt: now)
            }
            return .problem(completion.message ?? "Shortcuts reported an error without saying why.")
        case .success, .cancel:
            return shortcut == .send
                ? .installed(checkedAt: now)
                : .problem("A shortcut with that name ran, but it did not reach Operator. Install it again from the link.")
        }
    }
}
