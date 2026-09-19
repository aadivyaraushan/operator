import Foundation

/// Who writes a text that Operator sends. Either way it goes out through the
/// send shortcut with no confirmation tap.
enum MessageWriteMode: String, CaseIterable, Sendable {
    /// Operator asks the person for the words and sends exactly those.
    case custom
    /// The model writes the message.
    case auto

    var title: String {
        switch self {
        case .custom: "Custom message"
        case .auto: "Auto message"
        }
    }

    var summary: String {
        switch self {
        case .custom: "You write the message. Operator asks you for the words, then sends them."
        case .auto: "Operator writes the message and sends it for you."
        }
    }
}

protocol MessageWriteModeStore {
    func load() -> MessageWriteMode
    func save(_ mode: MessageWriteMode)
}

struct UserDefaultsMessageWriteModeStore: MessageWriteModeStore {
    private let defaults: UserDefaults
    static let key = "app.operator.messages.writeMode"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> MessageWriteMode {
        self.defaults.string(forKey: Self.key).flatMap(MessageWriteMode.init(rawValue:)) ?? .custom
    }

    func save(_ mode: MessageWriteMode) { self.defaults.set(mode.rawValue, forKey: Self.key) }
}
