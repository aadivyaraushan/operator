import Foundation

/// The side of a connector a grant covers. Every command the iPhone node
/// registers is one or the other; nothing is both.
public enum ConnectorAccess: String, Codable, CaseIterable, Sendable, Hashable {
    case read, write
}

/// A connector as the owner sees it on the Permissions page: one row, with a
/// read toggle and a write toggle. Commands are grouped under the connector a
/// person would recognise, not under the framework that implements them.
public enum ConnectorID: String, Codable, CaseIterable, Sendable, Hashable {
    case reminders, calendar, contacts, photos, music, location, weather, device
    case messages, maps, apps
    case whatsapp
    case google, microsoft, slack, spotify
    case notion
    case media
}

/// The iOS permission a connector also needs, when it needs one. Operator can
/// only ask for these and show their state; revoking them is done in iOS
/// Settings, which the page links to.
public enum SystemPermission: String, Sendable, Hashable {
    case reminders, calendars, contacts, photos, music, location
}

public struct ConnectorDescriptor: Sendable, Identifiable, Equatable {
    public let id: ConnectorID
    public let title: String
    /// What a read returns, in the owner's terms. Nil when the connector has no reads.
    public let readSummary: String?
    /// What a write does, and what still requires the owner's tap. Nil when it has no writes.
    public let writeSummary: String?
    public let readCommands: [String]
    public let writeCommands: [String]
    public let systemPermission: SystemPermission?
    /// True for connectors that also need a signed-in account before a grant means anything.
    public let requiresAccount: Bool

    public var hasReads: Bool { !self.readCommands.isEmpty }
    public var hasWrites: Bool { !self.writeCommands.isEmpty }
}

/// What a command needs before the node may run it.
public enum ConnectorRequirement: Equatable, Sendable {
    /// Metadata about Operator itself, not about the person. Never gated.
    case exempt
    case access(ConnectorID, ConnectorAccess)
}

public enum ConnectorCatalog {
    public static let all: [ConnectorDescriptor] = [
        .init(id: .reminders, title: "Reminders",
              readSummary: "Your incomplete reminders, soonest due first.",
              writeSummary: nil,
              readCommands: ["reminders.list"], writeCommands: [],
              systemPermission: .reminders, requiresAccount: false),
        .init(id: .calendar, title: "Calendar",
              readSummary: "Your events for the next seven days.",
              writeSummary: nil,
              readCommands: ["calendar.events"], writeCommands: [],
              systemPermission: .calendars, requiresAccount: false),
        .init(id: .contacts, title: "Contacts",
              readSummary: "Look up a person by name to get a number or email. Listing the whole address book is refused.",
              writeSummary: nil,
              readCommands: ["contacts.search"], writeCommands: [],
              systemPermission: .contacts, requiresAccount: false),
        .init(id: .photos, title: "Photos",
              readSummary: "When your most recent photos were taken and what kind they are. Never the pictures themselves.",
              writeSummary: nil,
              readCommands: ["photos.latest"], writeCommands: [],
              systemPermission: .photos, requiresAccount: false),
        .init(id: .music, title: "Music",
              readSummary: "What is playing now, and songs in your own library. No play, pause or skip.",
              writeSummary: nil,
              readCommands: ["music.nowPlaying", "music.search"], writeCommands: [],
              systemPermission: .music, requiresAccount: false),
        .init(id: .location, title: "Location",
              readSummary: "Where this iPhone is, only while Operator is open.",
              writeSummary: nil,
              readCommands: ["location.get"], writeCommands: [],
              systemPermission: .location, requiresAccount: false),
        .init(id: .weather, title: "Weather",
              readSummary: "The forecast for a place the agent names. Does not read your location.",
              writeSummary: nil,
              readCommands: ["weather.forecast"], writeCommands: [],
              systemPermission: nil, requiresAccount: false),
        .init(id: .device, title: "Device",
              readSummary: "Battery, charging, low power mode and whether you are online. No name or identifier.",
              writeSummary: nil,
              readCommands: ["device.status"], writeCommands: [],
              systemPermission: nil, requiresAccount: false),
        .init(id: .messages, title: "Messages",
              readSummary: nil,
              writeSummary: "Open a text with the recipient and message filled in. You tap Send.",
              readCommands: [], writeCommands: ["sms.compose"],
              systemPermission: nil, requiresAccount: false),
        .init(id: .maps, title: "Maps",
              readSummary: nil,
              writeSummary: "Open a place or directions in Apple Maps.",
              readCommands: [], writeCommands: ["maps.search", "maps.directions"],
              systemPermission: nil, requiresAccount: false),
        .init(id: .apps, title: "Open apps",
              readSummary: nil,
              writeSummary: "Open an approved app or its website inside Operator. It never completes anything there.",
              readCommands: [], writeCommands: ["apps.open"],
              systemPermission: nil, requiresAccount: false),
        .init(id: .whatsapp, title: "WhatsApp",
              readSummary: "Your chats and messages, once WhatsApp is linked.",
              writeSummary: "Send a message after you approve it.",
              readCommands: ["whatsapp.chats", "whatsapp.messages", "whatsapp.sync"], writeCommands: ["whatsapp.compose"],
              systemPermission: nil, requiresAccount: true),
        .init(id: .google, title: "Google",
              readSummary: "Calendar events, Drive files you have used with Operator, Gmail messages and Tasks.",
              writeSummary: "Create a calendar event or a Drive text file, after you approve it.",
              readCommands: ["connections.read"], writeCommands: ["connections.write"],
              systemPermission: nil, requiresAccount: true),
        .init(id: .microsoft, title: "Microsoft",
              readSummary: "Outlook inbox and calendar.",
              writeSummary: "Create a draft or send mail, after you approve it.",
              readCommands: ["connections.read"], writeCommands: ["connections.write"],
              systemPermission: nil, requiresAccount: true),
        .init(id: .slack, title: "Slack",
              readSummary: "Channel list and channel history.",
              writeSummary: "Post a message, after you approve it.",
              readCommands: ["connections.read"], writeCommands: ["connections.write"],
              systemPermission: nil, requiresAccount: true),
        .init(id: .spotify, title: "Spotify",
              readSummary: "Search and what is playing.",
              writeSummary: "Start playback, after you approve it.",
              readCommands: ["connections.read"], writeCommands: ["connections.write"],
              systemPermission: nil, requiresAccount: true),
        .init(id: .notion, title: "Notion",
              readSummary: "Search and read pages. Every call is confirmed with you first.",
              writeSummary: "Create, update or comment on pages, after you approve each one.",
              readCommands: ["notion.tools", "notion.call"], writeCommands: ["notion.call"],
              systemPermission: nil, requiresAccount: true),
        .init(id: .media, title: "YouTube & Podcasts",
              readSummary: "Search public videos and episodes.",
              writeSummary: "Open one inside Operator.",
              readCommands: ["youtube.search", "podcasts.search"], writeCommands: ["youtube.open", "podcasts.open"],
              systemPermission: nil, requiresAccount: false),
    ]

    public static func descriptor(_ id: ConnectorID) -> ConnectorDescriptor {
        // Every case is in `all`; the test suite pins that.
        self.all.first { $0.id == id }!
    }

    /// Commands whose payload names which connector they are about. The
    /// account commands carry an `operation`; Notion carries a tool `name`.
    private static let accountCommands: Set<String> = ["connections.read", "connections.write"]

    /// Notion MCP tools that only read. Anything not listed is treated as a
    /// write, so a tool this list has never heard of needs the write grant.
    private static let notionReadTools: Set<String> = [
        "notion-search", "notion-fetch", "notion-get-self", "notion-get-users",
        "notion-get-teams", "notion-get-comments",
    ]

    /// What `command` with `paramsJSON` needs. Nil means the command is not one
    /// this node knows, which the caller must treat as denied.
    public static func requirement(for command: String, paramsJSON: String?) -> ConnectorRequirement? {
        switch command {
        case "connections.describe":
            // Which providers are set up. State about Operator, not about the person.
            return .exempt
        case "connections.read", "connections.write":
            guard let operation = Self.field("operation", in: paramsJSON),
                  let provider = Self.provider(forAccountOperation: operation)
            else { return nil }
            return .access(provider, command == "connections.read" ? .read : .write)
        case "notion.tools":
            return .access(.notion, .read)
        case "notion.call":
            guard let name = Self.field("name", in: paramsJSON) else { return nil }
            return .access(.notion, Self.notionReadTools.contains(name) ? .read : .write)
        default:
            for descriptor in self.all where !Self.accountCommands.contains(command) {
                if descriptor.readCommands.contains(command) { return .access(descriptor.id, .read) }
                if descriptor.writeCommands.contains(command) { return .access(descriptor.id, .write) }
            }
            return nil
        }
    }

    private static func provider(forAccountOperation operation: String) -> ConnectorID? {
        if operation.hasPrefix("google") || operation.hasPrefix("gmail") { return .google }
        if operation.hasPrefix("outlook") { return .microsoft }
        if operation.hasPrefix("slack") { return .slack }
        if operation.hasPrefix("spotify") { return .spotify }
        return nil
    }

    private static func field(_ key: String, in paramsJSON: String?) -> String? {
        guard let paramsJSON, paramsJSON.utf8.count <= 64_000,
              let object = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any],
              let value = object[key] as? String, !value.isEmpty
        else { return nil }
        return value
    }
}

public enum ConnectorPermissionDecision: Equatable, Sendable {
    case allowed(ConnectorID?, ConnectorAccess?)
    case denied(ConnectorID, ConnectorAccess)
    case unknownCommand
}

/// What the owner has allowed. Starts empty: a fresh install permits nothing,
/// and the model is not even offered a tool it has not been granted.
public struct ConnectorGrants: Codable, Equatable, Sendable {
    /// Denies every write regardless of per-connector grants. One switch for
    /// "let it look, never let it act".
    public var readOnly: Bool
    private var granted: [ConnectorID: Set<ConnectorAccess>]

    public init(readOnly: Bool = false, granted: [ConnectorID: Set<ConnectorAccess>] = [:]) {
        self.readOnly = readOnly
        self.granted = granted
    }

    public static let none = ConnectorGrants()

    public func isGranted(_ id: ConnectorID, _ access: ConnectorAccess) -> Bool {
        self.granted[id]?.contains(access) ?? false
    }

    /// Whether a call would go through right now: the grant, and for writes
    /// the master switch as well.
    public func permits(_ id: ConnectorID, _ access: ConnectorAccess) -> Bool {
        if access == .write, self.readOnly { return false }
        return self.isGranted(id, access)
    }

    /// Write implies read: allowing a write grants the read it depends on, and
    /// revoking a read revokes the write above it.
    public mutating func set(_ id: ConnectorID, _ access: ConnectorAccess, allowed: Bool) {
        var current = self.granted[id] ?? []
        switch (access, allowed) {
        case (.read, true): current.insert(.read)
        case (.read, false): current = []
        case (.write, true): current = [.read, .write]
        case (.write, false): current.remove(.write)
        }
        if current.isEmpty { self.granted.removeValue(forKey: id) } else { self.granted[id] = current }
    }

    public var isEmpty: Bool { self.granted.isEmpty }

    public func decision(for command: String, paramsJSON: String?) -> ConnectorPermissionDecision {
        switch ConnectorCatalog.requirement(for: command, paramsJSON: paramsJSON) {
        case nil: return .unknownCommand
        case .exempt: return .allowed(nil, nil)
        case let .access(id, access):
            return self.permits(id, access) ? .allowed(id, access) : .denied(id, access)
        }
    }
}

extension GatewayNodeAgentTools {
    /// The tools to offer the model given what the owner has allowed. A
    /// connector without a read grant is not refused when called - it is not
    /// offered at all, so the model never plans around it.
    public static func descriptors(permittedBy grants: ConnectorGrants) -> [GatewayNodeAgentToolDescriptor] {
        self.descriptors.filter { descriptor in
            if case .allowed = grants.decision(for: descriptor.command, paramsJSON: nil) { return true }
            return false
        }
    }
}
