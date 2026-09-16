import Foundation
import OperatorCore
import OSLog

enum ConnectionDiscoverySetupState: String, Sendable {
    case idle, needsSetup, authorizing, connected, cancelled, failed, notChecked
}

struct ConnectionDiscoverySetupStatus: Sendable {
    let provider: String
    let state: ConnectionDiscoverySetupState
    let registrationAvailable: Bool

    var reportedState: ConnectionDiscoverySetupState {
        registrationAvailable ? state : .needsSetup
    }
}

@MainActor
final class ForegroundConnectionDiscoveryService: GatewayNodeCommandHandler {
    private let catalogData: Data
    private let setup: @MainActor @Sendable () -> [ConnectionDiscoverySetupStatus]
    private let logger = Logger(subsystem: "app.operator.ios", category: "connection-discovery")

    init(
        catalogData: Data,
        setup: @escaping @MainActor @Sendable () -> [ConnectionDiscoverySetupStatus]
    ) {
        self.catalogData = catalogData
        self.setup = setup
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?
    ) async -> GatewayNodeCommandResult {
        logger.info("[connection-discovery] input command=\(command, privacy: .public) has_params=\(paramsJSON != nil)")
        guard command == "connections.describe" else {
            logger.error("[connection-discovery] refused branch=unsupported_command")
            return .failure(code: "UNSUPPORTED_COMMAND", message: "Unsupported connection discovery command")
        }
        guard Self.isExactlyEmptyObject(paramsJSON) else {
            logger.error("[connection-discovery] refused branch=invalid_params")
            return .failure(code: "INVALID_REQUEST", message: "connections.describe requires exactly {}")
        }

        let appIDs = (try? AppHandoffCatalog.decode(catalogData).keys.sorted()) ?? []
        let object: [String: Any] = [
            "commands": GatewayNativeNodeSurface.commands,
            "commandDetails": GatewayNativeNodeSurface.commands.map(Self.detail(for:)),
            "accountOperations": [
                "read": Self.readOperations.map(\.rawValue),
                "write": AccountWriteOperation.allCases.map(\.rawValue),
                "readParameters": Self.readOperationParameters,
                "writeParameters": Self.writeOperationParameters,
            ],
            "setup": setup().prefix(16).map { ["provider": String($0.provider.prefix(64)), "state": $0.reportedState.rawValue] },
            "connectionStateNote": "Supported commands do not prove an account is connected. notChecked means this local description did not verify a stored session.",
            "appHandoffIDs": Array(appIDs.prefix(256)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object), data.count < 48_000 else {
            logger.error("[connection-discovery] failed branch=response_too_large")
            return .failure(code: "CONNECTIONS_UNAVAILABLE", message: "Connection descriptions are unavailable")
        }
        logger.info("[connection-discovery] output commands=\(GatewayNativeNodeSurface.commands.count) apps=\(appIDs.count) bytes=\(data.count)")
        return .success(payloadJSON: String(decoding: data, as: UTF8.self))
    }

    private static func isExactlyEmptyObject(_ text: String?) -> Bool {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        return dictionary.isEmpty
    }

    private static let readOperations: [AccountReadOperation] = [
        .googleCalendarEvents, .googleDriveFiles, .gmailMessages, .googleTasks, .outlookInbox, .outlookCalendarEvents, .slackChannels,
        .slackHistory, .spotifySearch, .spotifyPlayback,
    ]

    private static func detail(for command: String) -> [String: Any] {
        let parameters: [String: Any]
        let note: String
        switch command {
        case "location.get":
            parameters = schema(required: [], optional: [])
            note = "Returns the phone's current location when permission is available."
        case "calendar.events":
            parameters = schema(required: [], optional: ["start", "end"])
            note = "Reads on-device calendar events in an optional time range."
        case "reminders.list":
            parameters = schema(required: [], optional: ["limit"], limits: ["limit": "1...25"])
            note = "Reads incomplete on-device reminders. It cannot create, complete or delete one."
        case "contacts.search":
            parameters = schema(required: ["query"], optional: ["limit"], limits: ["query": "1...100 characters", "limit": "1...10"])
            note = "Looks up contacts matching a name. A query is required; the address book cannot be listed."
        case "photos.latest":
            parameters = schema(required: [], optional: ["album", "from", "to", "limit"], limits: ["limit": "1...25", "from": "RFC3339", "to": "RFC3339"])
            note = "Describes photos - identifiers, dates, kinds, albums. It never returns image data."
        case "music.nowPlaying":
            parameters = schema(required: [], optional: [])
            note = "Reports what the system music player is playing. It cannot start, stop or skip anything."
        case "music.search":
            parameters = schema(required: ["query"], optional: ["limit"], limits: ["limit": "1...20"])
            note = "Searches the owner's own music library. Playback is not offered."
        case "weather.forecast":
            parameters = schema(required: ["latitude", "longitude"], optional: [], limits: ["latitude": "-90...90", "longitude": "-180...180"])
            note = "Current conditions for an explicit coordinate. It does not read the phone's location; call location.get first."
        case "device.status":
            parameters = schema(required: [], optional: [])
            note = "Battery, power mode, connectivity, locale and time zone. It returns no identifier of any kind."
        case "sms.compose":
            parameters = schema(required: ["recipients", "body"], optional: [])
            note = "Opens the native message composer; the owner must tap Send."
        case "maps.search":
            parameters = schema(required: ["query"], optional: ["limit"], limits: ["limit": "1...10"])
            note = "Searches Apple Maps near the phone."
        case "maps.directions":
            parameters = schema(required: ["from", "to"], optional: ["transport"], limits: ["transport": "driving|walking|transit", "coordinate": "{lat:number,lon:number}"])
            note = "Returns up to 3 routes with bounded steps."
        case "apps.open":
            parameters = schema(required: ["appID"], optional: ["draft"])
            note = "Opens only an appID listed in appHandoffIDs; URL input is not accepted."
        case "whatsapp.chats":
            parameters = schema(required: [], optional: ["limit"], limits: ["limit": "1...50"])
            note = "Reads locally stored chats; it does not start pairing."
        case "whatsapp.messages":
            parameters = schema(required: ["chat"], optional: ["limit"], limits: ["chat": "1...256 characters", "limit": "1...50"])
            note = "Reads locally stored messages for one chat."
        case "whatsapp.sync":
            parameters = schema(required: [], optional: ["timeoutSeconds"], limits: ["timeoutSeconds": "1...60"])
            note = "Runs one explicit foreground sync; it does not start pairing."
        case "whatsapp.compose":
            parameters = schema(required: ["recipientJID", "body"], optional: [])
            note = "Shows an immutable native preview and sends once only after owner confirmation."
        case "connections.read":
            parameters = schema(required: ["operation"], optional: ["query", "channel", "timeMin", "timeMax", "limit", "cursor"])
            note = "Reads from a connected account; choose operation from accountOperations.read."
        case "connections.write":
            // The union of every operation's parameters, so this list cannot
            // fall behind writeParameters and make the model believe a field
            // does not exist (it once decided Meet links were impossible that way).
            let union = Self.writeOperationParameters.values.flatMap { $0 }.map { $0.hasSuffix("?") ? String($0.dropLast()) : $0 }
            parameters = schema(required: ["operation"], optional: Array(Set(union)).sorted())
            note = "Every write shows a native immutable preview and requires owner confirmation. Parameters per operation are in accountOperations.writeParameters (? marks optional). Google Calendar: googleCalendarCreateEvent takes attendees (invitations are emailed) and addMeetLink (a Google Meet room; its URL comes back as meetLink); googleCalendarUpdateEvent changes an existing event's summary, description, time, guest list, or adds a Meet room, by eventID from a read."
        case "connections.describe":
            parameters = schema(required: [], optional: [])
            note = "Describes the current native commands, account setup states, and supported app handoffs without network access."
        case "youtube.search":
            parameters = schema(required: ["query"], optional: ["limit"], limits: ["limit": "1...5"])
            note = "Searches YouTube and returns bounded public results."
        case "youtube.open":
            parameters = schema(required: ["videoID"], optional: [], limits: ["videoID": "exactly 11 characters"])
            note = "Opens one YouTube video by its validated video ID."
        case "podcasts.search":
            parameters = schema(required: ["feedURL"], optional: ["query", "limit"], limits: ["feedURL": "public HTTPS feed", "query": "1...200 bytes", "limit": "1...10"])
            note = "Searches a bounded public podcast feed."
        case "podcasts.open":
            parameters = schema(required: ["feedURL", "episodeID"], optional: [], limits: ["feedURL": "public HTTPS feed", "episodeID": "1...2048 characters"])
            note = "Opens one episode from a validated public podcast feed."
        case "discord.announcements":
            parameters = schema(required: [], optional: ["sinceRFC3339", "limit"], limits: ["limit": "1...50", "sinceRFC3339": "RFC3339"])
            note = "Reads the Discord announcement channels the person listed in Operator, through their own account. Rationed to a few passes a day; a refusal names when the next is possible. Read-only; channels cannot be chosen by the agent."
        case "contacts.create":
            parameters = schema(required: ["name"], optional: ["phones", "emails"], limits: ["name": "1...100 characters", "phones": "up to 3", "emails": "up to 3", "note": "at least one phone or email"])
            note = "Saves a new contact after the person sees it and taps Save. Refuses a number or email already in Contacts; never changes an existing contact."
        case "messages.incoming":
            parameters = schema(required: [], optional: ["sinceRFC3339", "limit"], limits: ["limit": "1...100", "sinceRFC3339": "RFC3339"])
            note = "Texts the person received since they set up the message automation, newest first. A feed, not the inbox: no history, no sent messages, no read state."
        case "notion.tools":
            parameters = schema(required: [], optional: [])
            note = "Lists bounded tools from the currently connected Notion server."
        case "notion.call":
            parameters = schema(required: ["name", "arguments"], optional: [], limits: ["name": "1...128 characters", "arguments": "JSON object", "request": "at most 65536 bytes"])
            note = "The name must come from the current notion.tools result; every call requires owner confirmation."
        default:
            parameters = schema(required: [], optional: [])
            note = "Use the command's native service contract."
        }
        return ["name": command, "parameters": parameters, "note": note]
    }

    private static func schema(required: [String], optional: [String], limits: [String: String] = [:]) -> [String: Any] {
        ["required": required, "optional": optional, "limits": limits, "unknownKeys": "rejected"]
    }

    private static let readOperationParameters: [String: [String]] = [
        "googleCalendarEvents": ["timeMin", "timeMax", "limit", "query?", "cursor?"],
        "googleDriveFiles": ["query", "limit", "cursor?"],
        "gmailMessages": ["limit", "query?", "cursor?"],
        "googleTasks": ["limit", "channel?", "cursor?"],
        "outlookInbox": ["limit", "query?", "cursor?"],
        "outlookCalendarEvents": ["timeMin", "timeMax", "limit", "cursor?"],
        "slackChannels": ["limit", "cursor?"],
        "slackHistory": ["channel", "limit", "cursor?"],
        "spotifySearch": ["query", "limit", "cursor?"],
        "spotifyPlayback": ["limit", "cursor?"],
    ]

    private static let writeOperationParameters: [String: [String]] = [
        "googleCalendarCreateEvent": ["summary", "description", "startRFC3339", "endRFC3339", "attendees?", "addMeetLink?"],
        "googleCalendarUpdateEvent": ["eventID", "summary?", "description?", "startRFC3339?", "endRFC3339?", "attendees?", "addMeetLink?"],
        "googleDriveCreateTextFile": ["name", "content"],
        "outlookCreateDraft": ["subject", "body"],
        "outlookSendMail": ["to", "subject", "body"],
        "slackPostMessage": ["channelID", "text"],
        "spotifyStartPlayback": ["trackURI", "deviceID?"],
    ]
}
