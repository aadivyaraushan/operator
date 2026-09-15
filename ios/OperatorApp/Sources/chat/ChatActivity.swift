import Foundation
import OperatorCore

/// One thing the agent did while answering: a tool call, named for a person.
struct ChatActivityStep: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case running, done, failed }

    /// The tool call id, so a result finds its start.
    let id: String
    let label: ChatActivityLabel
    var state: State

    var title: String { self.state == .running ? self.label.live : self.label.done }
}

/// What the agent is doing right now for the message in flight. Shown from
/// the moment the runtime accepts the message, so a long run is never a
/// bubble that says "Sending" and nothing else.
struct ChatLiveActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case thinking, writing }

    var steps: [ChatActivityStep] = []
    var phase: Phase = .thinking

    /// The line under the steps: what is happening that is not a step.
    var statusLine: String? {
        switch self.phase {
        case .writing: return nil
        case .thinking: return self.steps.contains { $0.state == .running } ? nil : "Thinking…"
        }
    }

    mutating func apply(_ activity: GatewayRunActivity) {
        switch activity {
        case let .toolStarted(tool, callID, command, operation):
            guard !self.steps.contains(where: { $0.id == callID }) else { return }
            self.steps.append(.init(id: callID, label: ChatActivityLabel.label(tool: tool, command: command, operation: operation), state: .running))
            // A tool after text means the agent is not done writing after all.
            self.phase = .thinking
        case let .toolFinished(_, callID, isError):
            guard let index = self.steps.firstIndex(where: { $0.id == callID }) else { return }
            self.steps[index].state = isError ? .failed : .done
        }
    }
}

/// Present and past forms of a step, e.g. "Reading Discord announcements" /
/// "Read Discord announcements".
struct ChatActivityLabel: Equatable, Sendable {
    let live: String
    let done: String

    /// Names the capability, not the tool: the runtime's node bridge is one
    /// tool ("nodes") that carries every phone command, so the command and,
    /// for connected accounts, the operation are what a person recognises.
    static func label(tool: String, command: String?, operation: String?) -> ChatActivityLabel {
        if let command, let known = Self.byCommand(command, operation: operation) { return known }
        if let known = Self.byTool[tool] { return known }
        let words = tool.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        return .init(live: "Using \(words)", done: "Used \(words)")
    }

    private static let byTool: [String: ChatActivityLabel] = [
        "discord_announcements": .init(live: "Reading Discord announcements", done: "Read Discord announcements"),
        "calendar_events": .init(live: "Checking your calendar", done: "Checked your calendar"),
        "reminders_list": .init(live: "Checking your reminders", done: "Checked your reminders"),
        "contacts_search": .init(live: "Looking up a contact", done: "Looked up a contact"),
        "photos_latest": .init(live: "Looking at recent photos", done: "Looked at recent photos"),
        "music_now_playing": .init(live: "Checking what's playing", done: "Checked what's playing"),
        "music_search": .init(live: "Searching your music", done: "Searched your music"),
        "weather_forecast": .init(live: "Checking the weather", done: "Checked the weather"),
        "device_status": .init(live: "Checking this iPhone", done: "Checked this iPhone"),
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
    ]

    private static func byCommand(_ command: String, operation: String?) -> ChatActivityLabel? {
        switch command {
        case "location.get": return .init(live: "Getting your location", done: "Got your location")
        case "calendar.events": return .init(live: "Checking your calendar", done: "Checked your calendar")
        case "reminders.list": return .init(live: "Checking your reminders", done: "Checked your reminders")
        case "contacts.search": return .init(live: "Looking up a contact", done: "Looked up a contact")
        case "photos.latest": return .init(live: "Looking at recent photos", done: "Looked at recent photos")
        case "music.nowPlaying": return .init(live: "Checking what's playing", done: "Checked what's playing")
        case "music.search": return .init(live: "Searching your music", done: "Searched your music")
        case "weather.forecast": return .init(live: "Checking the weather", done: "Checked the weather")
        case "device.status": return .init(live: "Checking this iPhone", done: "Checked this iPhone")
        case "sms.compose": return .init(live: "Preparing a text", done: "Prepared a text")
        case "sms.send": return .init(live: "Sending a text", done: "Sent a text")
        case "maps.search": return .init(live: "Looking up a place", done: "Looked up a place")
        case "maps.directions": return .init(live: "Getting directions", done: "Got directions")
        case "apps.open": return .init(live: "Opening an app", done: "Opened an app")
        case "whatsapp.chats", "whatsapp.messages", "whatsapp.sync": return .init(live: "Reading WhatsApp", done: "Read WhatsApp")
        case "whatsapp.compose": return .init(live: "Preparing a WhatsApp message", done: "Prepared a WhatsApp message")
        case "discord.announcements": return .init(live: "Reading Discord announcements", done: "Read Discord announcements")
        case "notion.tools", "notion.call": return .init(live: "Working in Notion", done: "Worked in Notion")
        case "youtube.search": return .init(live: "Searching YouTube", done: "Searched YouTube")
        case "youtube.open": return .init(live: "Opening YouTube", done: "Opened YouTube")
        case "podcasts.search": return .init(live: "Searching podcasts", done: "Searched podcasts")
        case "podcasts.open": return .init(live: "Opening a podcast", done: "Opened a podcast")
        case "connections.describe": return .init(live: "Checking connected accounts", done: "Checked connected accounts")
        case "connections.read": return Self.connection(operation, live: "Reading", done: "Read")
        case "connections.write": return Self.connection(operation, live: "Writing to", done: "Wrote to")
        default: return nil
        }
    }

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
