import Foundation

/// How long Operator thought before it started writing a reply, and what it
/// thought, kept with the reply for this launch: "Thought for 6s".
struct ChatThought: Equatable, Sendable {
    let seconds: Int
    let commentary: [String]
    let reasoning: String

    var label: String { Self.label(seconds: self.seconds) }
    var hasText: Bool { !self.commentary.isEmpty || !self.reasoning.isEmpty }

    /// Nil when it took under a second: nothing worth a line.
    init?(from start: Date, to end: Date, activity: ChatLiveActivity?) {
        let seconds = Int(end.timeIntervalSince(start).rounded())
        guard seconds >= 1 else { return nil }
        self.seconds = seconds
        self.commentary = activity?.commentary ?? []
        self.reasoning = activity?.reasoning ?? ""
    }

    static func label(seconds: Int) -> String {
        seconds < 60 ? "Thought for \(seconds)s" : "Thought for \(seconds / 60)m \(seconds % 60)s"
    }
}
