import Foundation
import OperatorCore

/// One tool call the agent made while answering, shown the way a terminal
/// agent shows it: the exact tool and its arguments, e.g.
/// `whatsapp.compose(recipient: "+1 555…", body: "on my way")`.
struct ChatActivityStep: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case running, done, failed }

    /// The tool call id, so a result finds its start.
    let id: String
    /// The tool as the agent named it, unwrapped: the runtime's node bridge
    /// is one tool ("nodes") carrying every phone command, so for it this is
    /// the command (`whatsapp.compose`), not the bridge.
    let name: String
    /// `key: value, key: value`, bounded, or empty.
    let arguments: String
    var state: State

    /// `name(arguments)`.
    var title: String { self.arguments.isEmpty ? "\(self.name)()" : "\(self.name)(\(self.arguments))" }

    init(id: String, name: String, arguments: String, state: State) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.state = state
    }

    init(id: String, tool: String, arguments: [String: JSONValue], state: State) {
        let call = ChatActivityFormatter.call(tool: tool, arguments: arguments)
        self.init(id: id, name: call.name, arguments: call.arguments, state: state)
    }
}

/// What the agent is doing right now for the message in flight. Present from
/// the moment the message is sent, so the person always has something on
/// screen: three dots while the model thinks, each tool as it runs, then the
/// text as it streams.
struct ChatLiveActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case thinking, writing }

    var steps: [ChatActivityStep] = []
    var phase: Phase = .thinking

    mutating func apply(_ activity: GatewayRunActivity) {
        switch activity {
        case let .toolStarted(tool, callID, arguments):
            guard !self.steps.contains(where: { $0.id == callID }) else { return }
            self.steps.append(.init(id: callID, tool: tool, arguments: arguments, state: .running))
            // A tool after text means the agent is not done writing after all.
            self.phase = .thinking
        case let .toolFinished(_, callID, isError):
            guard let index = self.steps.firstIndex(where: { $0.id == callID }) else { return }
            self.steps[index].state = isError ? .failed : .done
        }
    }
}

/// Turns a tool call into `name` and a one-line argument summary.
enum ChatActivityFormatter {
    static let argumentLimit = 3
    static let valueLimit = 48
    static let lineLimit = 120

    /// Keys shown first when present, in this order; the rest follow by name.
    private static let leadingKeys = ["operation", "command", "query", "recipient", "to", "name", "url", "path", "channel", "limit"]
    /// Bookkeeping the runtime adds that says nothing about the call.
    private static let hiddenKeys: Set<String> = ["action", "node", "invokeTimeoutMs", "timeoutMs", "gatewayUrl", "gatewayToken"]

    static func call(tool: String, arguments: [String: JSONValue]) -> (name: String, arguments: String) {
        var name = tool
        var arguments = arguments
        // The node bridge: nodes(action: invoke, invokeCommand: X, invokeParamsJson: "{…}")
        // is shown as X(…the parameters…).
        if tool == "nodes", let command = arguments["invokeCommand"]?.stringValue, !command.isEmpty {
            name = command
            let params = arguments["invokeParamsJson"]?.stringValue.flatMap(JSONValue.parse)?.objectValue ?? [:]
            arguments = params
        }
        return (name, Self.summary(arguments))
    }

    static func summary(_ arguments: [String: JSONValue]) -> String {
        let keys = arguments.keys.filter { !Self.hiddenKeys.contains($0) }
        let ordered = Self.leadingKeys.filter { keys.contains($0) } + keys.filter { !Self.leadingKeys.contains($0) }.sorted()
        var parts: [String] = []
        for key in ordered.prefix(Self.argumentLimit) {
            guard let value = arguments[key] else { continue }
            parts.append("\(key): \(Self.render(value))")
        }
        if ordered.count > Self.argumentLimit { parts.append("…") }
        let line = parts.joined(separator: ", ")
        return line.count > Self.lineLimit ? String(line.prefix(Self.lineLimit - 1)) + "…" : line
    }

    private static func render(_ value: JSONValue) -> String {
        switch value {
        case let .string(text):
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            let cut = flat.count > Self.valueLimit ? String(flat.prefix(Self.valueLimit - 1)) + "…" : flat
            return "\"\(cut)\""
        case let .number(number):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case let .bool(flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case let .array(items):
            return "[\(items.count) item\(items.count == 1 ? "" : "s")]"
        case let .object(fields):
            return "{\(fields.count) field\(fields.count == 1 ? "" : "s")}"
        }
    }
}
