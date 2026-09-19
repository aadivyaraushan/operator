import Foundation

/// Descriptors that make node commands reachable by the agent.
///
/// Registering a command with the gateway is not enough for the model to be
/// able to call it. openclaw builds the agent's tool list from descriptors a
/// node publishes with `node.pluginTools.update`; a node that publishes none
/// gets no tools, and the model then answers from its own built-ins. That was
/// the whole of the "nothing is recorded for today" bug - the surface paired
/// cleanly and `reminders.list` was never invoked, which the simulator's TCC
/// database confirmed by having no row for the app at all.
///
/// Measured against openclaw 2026.9.1, a published descriptor survives
/// normalization only when all of these hold:
///
///   - `pluginId`, `description` and `command` are non-empty
///   - `name` matches `^[A-Za-z][A-Za-z0-9_-]{0,63}$` - so a tool cannot be
///     named after its own dotted command; `reminders.list` is not a legal
///     tool name, `reminders_list` is
///   - `command` is one of the commands this node registered on connect
///   - at most 128 descriptors, deduplicated by `pluginId` + `name`
///
/// `gateway.nodes.pluginTools.enabled` defaults to true, so nothing needs to
/// be configured for these to be accepted.
public enum GatewayNodeAgentTools {
    public static let pluginID = "operator-ios"

    /// Read tools and the bounded review of existing owner-requested conversations.
    ///
    /// Publishing a tool is what lets the model decide on its own to call a
    /// command, so this list is where "reads before writes" is actually
    /// enforced for the agent. Composing a message, opening an app, writing a
    /// connection or anything in the hand-off pack stays off it deliberately:
    /// those are reachable only through a surface the person drove.
    public static let descriptors: [GatewayNodeAgentToolDescriptor] = [
        .init(name: "messages_conversation_review", command: "messages.conversation.review",
              description: "Review an existing owner-requested conversation after reading messages_conversations. Record evidenced answers, optionally write a natural followupMessage, or omit it to wait. Cannot create tasks or change recipients. Sending requires the owner's automatic messaging permission.",
              parameters: .init(properties: [
                "taskID": .string("Existing task ID."),
                "revision": .integer("Latest task revision from messages_conversations."),
                "answersJSON": .string("JSON array of {questionID,messageID,quote,answer,remainingQuestion?}. Use [] if no answers."),
                "followupMessage": .string("Optional natural-language reply if another message would help. Omit to wait."),
                "stopReason": .string("Optional reason to stop for owner attention, such as recipient refusal.")
              ], required: ["taskID", "revision", "answersJSON"])),
        .init(name: "messages_conversations", command: "messages.conversations",
              description: "Read persistent conversation tasks, their approved questions, recipient handles, captured replies, revisions and answer evidence. Use for conversation progress and app-generated task reviews. Use messages_conversation_review to review replies. To propose use messages.conversation through the phone node. Never send separately: the task scheduler owns sends.", parameters: .init()),
        .init(
            name: "reminders_list",
            command: "reminders.list",
            description: """
            List the person's own incomplete reminders from this iPhone, soonest due first. \
            Use for questions like "what is still open", "what do I owe someone", or anything \
            on their to-do list. Read-only: it cannot add, complete or delete a reminder.
            """,
            parameters: .init(properties: [
                "limit": .integer("How many reminders to return, 1 to 25. Defaults to 25."),
            ])),
        .init(
            name: "calendar_events",
            command: "calendar.events",
            description: """
            Read the person's own upcoming calendar events on this iPhone - everything from \
            now through the next seven days, soonest first, up to 25. Use for "am I free", \
            "what is on today", or checking a conflict before suggesting a time, and filter \
            the returned events yourself for the window the person asked about. Takes no \
            arguments. Read-only: it cannot create, move or cancel an event.
            """,
            parameters: .init()),
        .init(
            name: "contacts_search",
            command: "contacts.search",
            description: """
            Find people in the person's own contacts on this iPhone by name, to turn a first \
            name into a phone number or email. A query is required and the address book cannot \
            be listed: asking for "all my contacts" is refused by design.
            """,
            parameters: .init(
                properties: [
                    "query": .string("Name or part of a name to search for. Required."),
                    "limit": .integer("How many people to return, 1 to 10. Defaults to 10."),
                ],
                required: ["query"])),
        .init(
            name: "photos_latest",
            command: "photos.latest",
            description: """
            Describe the most recent photos in the person's own library on this iPhone - when \
            each was taken and what kind of asset it is. Returns descriptions and dates only; \
            no image data ever leaves the device, so it cannot show or send a picture.
            """,
            parameters: .init(properties: [
                "limit": .integer("How many photos to describe, 1 to 25. Defaults to 25."),
            ])),
        .init(
            name: "music_now_playing",
            command: "music.nowPlaying",
            description: """
            Report what is playing right now on this iPhone, if anything. Read-only: there is \
            no play, pause or skip - asking to control playback is refused by design.
            """,
            parameters: .init()),
        .init(
            name: "music_search",
            command: "music.search",
            description: """
            Search the person's own music library on this iPhone by title or artist. Read-only: \
            it returns what it found and cannot start playback.
            """,
            parameters: .init(
                properties: [
                    "query": .string("Title or artist to search for. Required."),
                    "limit": .integer("How many songs to return, 1 to 25. Defaults to 25."),
                ],
                required: ["query"])),
        .init(
            name: "weather_forecast",
            command: "weather.forecast",
            description: """
            Get the forecast for an explicit latitude and longitude. Both are required - it \
            will not infer where the person is. Any summary must keep the attribution string \
            the result carries.
            """,
            parameters: .init(
                properties: [
                    "latitude": .number("Latitude in degrees, -90 to 90. Required."),
                    "longitude": .number("Longitude in degrees, -180 to 180. Required."),
                ],
                required: ["latitude", "longitude"])),
        .init(
            name: "device_status",
            command: "device.status",
            description: """
            Report this iPhone's battery level, charging state, low-power mode and whether it \
            is online. Carries no name, model or identifier of any kind.
            """,
            parameters: .init()),
        .init(
            name: "discord_announcements",
            command: "discord.announcements",
            description: """
            Read the newest messages in the Discord announcement channels the person chose in \
            Operator, through their own account. Use for "what did I miss", "any announcements", \
            or to find dated items to put on their calendar. To protect the account each channel \
            is requested at most once every ten minutes, with a daily cap; a channel read more \
            recently comes back from that read (fromCache true on the channel, readAt says \
            when), and if the whole call is refused, say so and do not retry. Read-only: it \
            cannot post, react, or mark anything read, and it cannot read a channel the person \
            has not listed.
            """,
            parameters: .init(properties: [
                "sinceRFC3339": .string("Only messages after this time. Omit to get the newest messages in each channel."),
                "limit": .integer("Newest messages per channel, 1 to 50. Defaults to 25."),
            ])),
        .init(
            name: "canvas_courses",
            command: "canvas.courses",
            description: """
            The person's active Canvas courses, with the current score and letter grade where \
            the course shows one. Use for "what classes am I in", "what's my grade in X", or \
            to get a course's id and name before reading its announcements. Takes no \
            arguments. Read-only.
            """,
            parameters: .init()),
        .init(
            name: "canvas_upcoming",
            command: "canvas.upcoming",
            description: """
            What is due in the person's Canvas courses over the next days - assignments, \
            quizzes, discussions, events - soonest first, each with its course, due time, \
            points and whether it is already submitted, missing or late; plus anything past \
            due and unsubmitted. Use for "what's due", "what do I have this week", "what do I \
            owe". Read-only: it cannot submit or change anything.
            """,
            parameters: .init(properties: [
                "days": .integer("How many days ahead to look, 1 to 30. Defaults to 7."),
            ])),
        .init(
            name: "canvas_announcements",
            command: "canvas.announcements",
            description: """
            Recent announcements across the person's active Canvas courses, newest first, \
            with course, author, time, the text and a link. Use for "any announcements", \
            "what did I miss in class", or "did the professor post anything". Read-only.
            """,
            parameters: .init(properties: [
                "days": .integer("How many days back to look, 1 to 60. Defaults to 14."),
                "limit": .integer("How many announcements at most, 1 to 50. Defaults to 20."),
            ])),
        .init(
            name: "messages_incoming",
            command: "messages.incoming",
            description: """
            The texts (SMS and iMessage) the person has received since they set up Operator's \
            message automation, newest first, with sender and time. Use for "did anyone text me", \
            "what did X say", or to summarise a thread. It is a feed, not the inbox: nothing older \
            than the setup, no texts sent directly in Messages, no read state, no attachments. Includes texts sent through Operator with direction sent and to recipients. To reply, use \
            the Messages send tools.
            """,
            parameters: .init(properties: [
                "sinceRFC3339": .string("Only texts received after this time. Omit for the newest."),
                "limit": .integer("How many, 1 to 100. Defaults to 25."),
            ])),
    ]

    /// Every published command must be one this node actually registered, or
    /// the gateway drops the descriptor and the tool silently disappears.
    public static var publishedCommands: [String] {
        self.descriptors.map(\.command)
    }
}

public struct GatewayNodeAgentToolDescriptor: Encodable, Equatable, Sendable {
    public let pluginId: String
    public let name: String
    public let description: String
    public let parameters: GatewayNodeAgentToolSchema
    public let command: String

    public init(
        name: String,
        command: String,
        description: String,
        parameters: GatewayNodeAgentToolSchema)
    {
        self.pluginId = GatewayNodeAgentTools.pluginID
        self.name = name
        self.command = command
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parameters = parameters
    }
}

/// The JSON Schema shape openclaw expects for a tool's arguments.
public struct GatewayNodeAgentToolSchema: Encodable, Equatable, Sendable {
    public struct Property: Encodable, Equatable, Sendable {
        public let type: String
        public let description: String

        public static func string(_ description: String) -> Self {
            .init(type: "string", description: description)
        }

        public static func integer(_ description: String) -> Self {
            .init(type: "integer", description: description)
        }

        public static func number(_ description: String) -> Self {
            .init(type: "number", description: description)
        }
    }

    public let type = "object"
    public let properties: [String: Property]
    public let required: [String]
    public let additionalProperties = false

    public init(properties: [String: Property] = [:], required: [String] = []) {
        self.properties = properties
        self.required = required
    }

    private enum CodingKeys: String, CodingKey {
        case type, properties, required, additionalProperties
    }
}
