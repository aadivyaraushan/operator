import Foundation
import OperatorCore
import OSLog

/// `discord.announcements`: one pass over the owner's channel list.
///
/// Everything the acknowledgement promises is checked here or in the client:
/// only the listed channels, one request each, the pace guard before any
/// request, a 429 ends the pass and pauses the connector for a day, and the
/// payload is written so the model knows when not to ask again. A pass the
/// guard refuses is answered from the previous pass when there is one, marked
/// as such: Discord sees nothing either way.
@MainActor
final class ForegroundDiscordAnnouncementsService: GatewayNodeCommandHandler {
    static let command = "discord.announcements"
    static let defaultLimit = 25

    private let client: DiscordUserClient
    private let channels: @MainActor () -> [DiscordChannelEntry]
    private let pace: DiscordReadPace
    private let cache: any DiscordReadCacheStore
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "discord-read")

    init(
        client: DiscordUserClient,
        channels: @escaping @MainActor () -> [DiscordChannelEntry],
        pace: DiscordReadPace,
        cache: any DiscordReadCacheStore,
        now: @escaping () -> Date = Date.init)
    {
        self.client = client
        self.channels = channels
        self.pace = pace
        self.cache = cache
        self.now = now
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult {
        guard command == Self.command else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let parameters = Self.parameters(from: paramsJSON) else {
            return .failure(code: "INVALID_REQUEST", message: "discord.announcements takes optional sinceRFC3339 and limit (1 to 50) and nothing else")
        }
        let list = self.channels()
        guard !list.isEmpty else {
            return .failure(code: "NOT_CONFIGURED", message: "No Discord channels are listed. The person adds them under Connect accounts > Discord; the agent cannot choose channels.")
        }
        if let refusal = self.pace.check() {
            if let previous = self.previousPass(listed: list, parameters: parameters) {
                self.logger.info("[discord-read] refused code=\(refusal.code, privacy: .public) served=previous-pass")
                return self.result(
                    channels: previous.channels, readAt: previous.readAt, fromCache: true,
                    note: [refusal.message, Self.cacheNote(readAt: previous.readAt, now: self.now()), previous.note].compactMap { $0 }.joined(separator: " "))
            }
            self.logger.info("[discord-read] refused code=\(refusal.code, privacy: .public)")
            return .failure(code: refusal.code, message: refusal.message)
        }
        // Counted before the first request: Discord sees the requests whether
        // or not the pass completes.
        self.pace.recordPass()
        self.logger.info("[discord-read] pass started channels=\(list.count) limit=\(parameters.limit)")

        var read: [DiscordReadCache.Channel] = []
        var note: String?
        var totalMessages = 0
        for channel in list {
            do {
                let messages = try await self.client.messages(in: channel, limit: parameters.limit)
                totalMessages += messages.count
                read.append(.init(
                    id: channel.id, name: channel.name, server: channel.guildName,
                    messages: messages.map {
                        .init(id: $0.id, at: $0.timestampRFC3339, author: $0.author, text: $0.text, link: $0.link, attachments: $0.attachmentCount)
                    },
                    error: nil))
            } catch DiscordUserClientError.notConnected {
                self.logger.info("[discord-read] pass ended reason=not-connected")
                return .failure(code: "NOT_CONNECTED", message: "Discord did not accept the saved token. The person can save a new one under Connect accounts > Discord.")
            } catch let DiscordUserClientError.rateLimited(seconds) {
                self.pace.recordRateLimit()
                note = "Discord asked Operator to slow down (retry after \(seconds)s), so this pass stopped early and Discord reads are paused for a day. Report what was read; do not retry."
                self.logger.info("[discord-read] pass ended reason=rate-limited")
                break
            } catch DiscordUserClientError.notVisible {
                read.append(.init(id: channel.id, name: channel.name, server: channel.guildName, messages: [], error: "not visible to this account"))
            } catch {
                read.append(.init(id: channel.id, name: channel.name, server: channel.guildName, messages: [], error: "could not be read"))
            }
        }
        self.logger.info("[discord-read] pass complete channels=\(read.count) messages=\(totalMessages)")
        let readAt = self.now()
        // A pass that read nothing (every channel failed, or a 429 came first)
        // must not replace a previous pass that did.
        if read.contains(where: { $0.error == nil }) {
            self.cache.save(.init(readAt: readAt, limit: parameters.limit, channels: read, note: note))
        }
        return self.result(channels: Self.apply(parameters, to: read), readAt: readAt, fromCache: false, note: note)
    }

    /// The previous pass, cut to the channels the owner lists now: a channel
    /// removed from the list is not read, cached or otherwise.
    private func previousPass(listed: [DiscordChannelEntry], parameters: Parameters) -> DiscordReadCache? {
        guard let cached = self.cache.load() else { return nil }
        let ids = Set(listed.map(\.id))
        let channels = Self.apply(parameters, to: cached.channels.filter { ids.contains($0.id) })
        guard channels.contains(where: { $0.error == nil }) else { return nil }
        return .init(readAt: cached.readAt, limit: cached.limit, channels: channels, note: cached.note)
    }

    private static func apply(_ parameters: Parameters, to channels: [DiscordReadCache.Channel]) -> [DiscordReadCache.Channel] {
        channels.map { channel in
            var messages = channel.messages
            if let since = parameters.since {
                messages = messages.filter { Self.date($0.at).map { $0 > since } ?? true }
            }
            return .init(id: channel.id, name: channel.name, server: channel.server, messages: Array(messages.prefix(parameters.limit)), error: channel.error)
        }
    }

    private static func cacheNote(readAt: Date, now: Date) -> String {
        let minutes = max(1, Int((now.timeIntervalSince(readAt) / 60).rounded()))
        return "What follows is the previous read, made \(minutes) minutes ago, not a new one; say when it was read."
    }

    private func result(channels: [DiscordReadCache.Channel], readAt: Date, fromCache: Bool, note: String?) -> GatewayNodeCommandResult {
        var payload: [String: Any] = [
            "channels": channels.map { channel -> [String: Any] in
                var object: [String: Any] = ["id": channel.id, "channel": channel.name, "server": channel.server]
                if let error = channel.error {
                    object["error"] = error
                } else {
                    object["messages"] = channel.messages.map { message -> [String: Any] in
                        ["id": message.id, "at": message.at, "author": message.author, "text": message.text, "link": message.link, "attachments": message.attachments]
                    }
                }
                return object
            },
            "readAt": ISO8601DateFormatter().string(from: readAt),
            "fromCache": fromCache,
            "passesLeftToday": self.pace.passesLeftToday,
            "nextStep": "Summarise per server, newest first. Offer anything with a date or time as a calendar event (googleCalendarCreateEvent, with the message link in the description) and let the person choose. Reads are rationed; do not call this again in the same conversation unless the person asks for a fresh read.",
        ]
        if let note { payload["note"] = note }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 262_144 else {
            return .failure(code: "RESPONSE_TOO_LARGE", message: "The announcements were too large to return; ask for fewer per channel with limit")
        }
        return .success(payloadJSON: String(decoding: data, as: UTF8.self))
    }

    private struct Parameters {
        let since: Date?
        let limit: Int
    }

    private static func parameters(from paramsJSON: String?) -> Parameters? {
        guard let paramsJSON, paramsJSON.utf8.count <= 4_096 else { return Parameters(since: nil, limit: Self.defaultLimit) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any],
              Set(object.keys).isSubset(of: ["sinceRFC3339", "limit"])
        else { return nil }
        var since: Date?
        if let raw = object["sinceRFC3339"], !(raw is NSNull) {
            guard let text = raw as? String, let date = Self.date(text) else { return nil }
            since = date
        }
        var limit = Self.defaultLimit
        if let raw = object["limit"], !(raw is NSNull) {
            guard let number = raw as? NSNumber, (1...50).contains(number.intValue) else { return nil }
            limit = number.intValue
        }
        return Parameters(since: since, limit: limit)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
