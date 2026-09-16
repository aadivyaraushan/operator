import Foundation
import OperatorCore

/// One tool call the agent made while answering, shown in plain words:
/// "Checking Discord announcements", then "Checked Discord announcements".
/// The exact call (`discord_announcements(limit: 25)`) is kept for the
/// accessibility label and for tools the words do not cover.
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
    let label: ChatActivityLabel
    var state: State

    /// What the row says: present tense while running, past once done.
    var title: String { self.state == .running ? self.label.live : self.label.done }

    /// `name(arguments)`, the exact call.
    var call: String { self.arguments.isEmpty ? "\(self.name)()" : "\(self.name)(\(self.arguments))" }

    init(id: String, name: String, arguments: String, label: ChatActivityLabel, state: State) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.label = label
        self.state = state
    }

    init(id: String, tool: String, arguments: [String: JSONValue], state: State) {
        let call = ChatActivityFormatter.call(tool: tool, arguments: arguments)
        self.init(id: id, name: call.name, arguments: call.arguments, label: ChatActivityLabel.label(for: call.name, arguments: call.parameters), state: state)
    }
}

/// Present and past forms of a step in a person's words.
struct ChatActivityLabel: Equatable, Sendable {
    let live: String
    let done: String

    /// Names the capability the way the Permissions page does. `name` is the
    /// unwrapped tool (a phone command for the node bridge); `arguments` are
    /// its parameters, used for the connected-account operation.
    static func label(for name: String, arguments: [String: JSONValue]) -> ChatActivityLabel {
        if let known = Self.known[name] { return known }
        if name == "connections.read" { return Self.connection(arguments["operation"]?.stringValue, live: "Reading", done: "Read") }
        if name == "connections.write" { return Self.connection(arguments["operation"]?.stringValue, live: "Writing to", done: "Wrote to") }
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        return .init(live: "Using \(words)", done: "Used \(words)")
    }

    private static let known: [String: ChatActivityLabel] = [
        // Phone commands, as the node bridge names them.
        "discord.announcements": .init(live: "Checking Discord announcements", done: "Checked Discord announcements"),
        "messages.incoming": .init(live: "Checking your texts", done: "Checked your texts"),
        "location.get": .init(live: "Getting your location", done: "Got your location"),
        "calendar.events": .init(live: "Checking your calendar", done: "Checked your calendar"),
        "reminders.list": .init(live: "Checking your reminders", done: "Checked your reminders"),
        "contacts.search": .init(live: "Looking up a contact", done: "Looked up a contact"),
        "photos.latest": .init(live: "Looking at recent photos", done: "Looked at recent photos"),
        "music.nowPlaying": .init(live: "Checking what's playing", done: "Checked what's playing"),
        "music.search": .init(live: "Searching your music", done: "Searched your music"),
        "weather.forecast": .init(live: "Checking the weather", done: "Checked the weather"),
        "device.status": .init(live: "Checking this iPhone", done: "Checked this iPhone"),
        "sms.compose": .init(live: "Preparing a text", done: "Prepared a text"),
        "sms.send": .init(live: "Sending a text", done: "Sent a text"),
        "maps.search": .init(live: "Looking up a place", done: "Looked up a place"),
        "maps.directions": .init(live: "Getting directions", done: "Got directions"),
        "apps.open": .init(live: "Opening an app", done: "Opened an app"),
        "whatsapp.chats": .init(live: "Checking WhatsApp chats", done: "Checked WhatsApp chats"),
        "whatsapp.messages": .init(live: "Reading WhatsApp messages", done: "Read WhatsApp messages"),
        "whatsapp.sync": .init(live: "Syncing WhatsApp", done: "Synced WhatsApp"),
        "whatsapp.compose": .init(live: "Preparing a WhatsApp message", done: "Prepared a WhatsApp message"),
        "notion.tools": .init(live: "Checking Notion", done: "Checked Notion"),
        "notion.call": .init(live: "Working in Notion", done: "Worked in Notion"),
        "youtube.search": .init(live: "Searching YouTube", done: "Searched YouTube"),
        "youtube.open": .init(live: "Opening YouTube", done: "Opened YouTube"),
        "podcasts.search": .init(live: "Searching podcasts", done: "Searched podcasts"),
        "podcasts.open": .init(live: "Opening a podcast", done: "Opened a podcast"),
        "connections.describe": .init(live: "Checking connected accounts", done: "Checked connected accounts"),
        // The same capabilities when published to the model as tools.
        "discord_announcements": .init(live: "Checking Discord announcements", done: "Checked Discord announcements"),
        "messages_incoming": .init(live: "Checking your texts", done: "Checked your texts"),
        "calendar_events": .init(live: "Checking your calendar", done: "Checked your calendar"),
        "reminders_list": .init(live: "Checking your reminders", done: "Checked your reminders"),
        "contacts_search": .init(live: "Looking up a contact", done: "Looked up a contact"),
        "photos_latest": .init(live: "Looking at recent photos", done: "Looked at recent photos"),
        "music_now_playing": .init(live: "Checking what's playing", done: "Checked what's playing"),
        "music_search": .init(live: "Searching your music", done: "Searched your music"),
        "weather_forecast": .init(live: "Checking the weather", done: "Checked the weather"),
        "device_status": .init(live: "Checking this iPhone", done: "Checked this iPhone"),
        // The runtime's own tools.
        "web_search": .init(live: "Searching the web", done: "Searched the web"),
        "web_fetch": .init(live: "Reading a web page", done: "Read a web page"),
        "browser": .init(live: "Using the browser", done: "Used the browser"),
        "exec": .init(live: "Running a command", done: "Ran a command"),
        "bash": .init(live: "Running a command", done: "Ran a command"),
        "read": .init(live: "Reading a file", done: "Read a file"),
        "write": .init(live: "Writing a file", done: "Wrote a file"),
        "edit": .init(live: "Editing a file", done: "Edited a file"),
        "memory_search": .init(live: "Searching memory", done: "Searched memory"),
        "memory_get": .init(live: "Reading memory", done: "Read memory"),
        "message": .init(live: "Sending a message", done: "Sent a message"),
        "nodes": .init(live: "Checking this iPhone's tools", done: "Checked this iPhone's tools"),
    ]

    private static func connection(_ operation: String?, live: String, done: String) -> ChatActivityLabel {
        let service: String = switch operation {
        case "gmailMessages": "Gmail"
        case "googleCalendarEvents", "googleCalendarCreateEvent", "googleCalendarUpdateEvent": "Google Calendar"
        case "googleDriveFiles", "googleDriveCreateTextFile": "Google Drive"
        case "googleTasks": "Google Tasks"
        case "outlookInbox", "outlookCreateDraft", "outlookSendMail": "Outlook"
        case "outlookCalendarEvents": "Outlook Calendar"
        case "slackChannels", "slackHistory", "slackPostMessage": "Slack"
        case "spotifyPlayback", "spotifySearch", "spotifyStartPlayback": "Spotify"
        default: "a connected account"
        }
        return .init(live: "\(live) \(service)", done: "\(done) \(service)")
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
    /// The model's reasoning so far, when the runtime streams it. Shown
    /// while drafting, gone with the reply.
    var reasoning = ""
    /// What the model said it was about to do, in order. Same lifetime.
    var commentary: [String] = []

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
        case let .thinking(text):
            self.reasoning = text
        case let .commentary(text):
            guard self.commentary.last != text else { return }
            self.commentary.append(text)
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

    static func call(tool: String, arguments: [String: JSONValue]) -> (name: String, arguments: String, parameters: [String: JSONValue]) {
        var name = tool
        var arguments = arguments
        // The node bridge: nodes(action: invoke, invokeCommand: X, invokeParamsJson: "{…}")
        // is shown as X(…the parameters…).
        if tool == "nodes", let command = arguments["invokeCommand"]?.stringValue, !command.isEmpty {
            name = command
            let params = arguments["invokeParamsJson"]?.stringValue.flatMap(JSONValue.parse)?.objectValue ?? [:]
            arguments = params
        }
        return (name, Self.summary(arguments), arguments)
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
