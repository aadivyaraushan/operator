import Foundation
import OperatorCore
import OSLog

/// `discord.announcements`: one pass over the owner's channel list.
///
/// Everything the acknowledgement promises is checked here or in the client:
/// only the listed channels, one request each, each channel at most once per
/// cooldown, the pass cap before any request, a 429 ends the pass and pauses
/// the connector for a day, and the payload is written so the model knows
/// when not to ask again. A channel inside its cooldown is answered from its
/// last read, marked as such: Discord sees nothing for it either way.
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
        // Only listed channels are ever served or kept: a channel the owner
        // removed is not read, cached or otherwise.
        let listedIDs = Set(list.map(\.id))
        var kept = Dictionary(uniqueKeysWithValues: (self.cache.load()?.channels ?? []).filter { listedIDs.contains($0.id) }.map { ($0.id, $0) })
        let current = self.now()

        if let refusal = self.pace.check() {
            guard kept.values.contains(where: { $0.error == nil }) else {
                self.logger.info("[discord-read] refused code=\(refusal.code, privacy: .public)")
                return .failure(code: refusal.code, message: refusal.message)
            }
            self.logger.info("[discord-read] refused code=\(refusal.code, privacy: .public) served=last-reads")
            return self.result(list, from: kept, parameters: parameters, at: current, note: refusal.message + " " + Self.servedNote)
        }
        // A channel inside its cooldown is served from its last read; one
        // whose last read is missing (the file is gone) is read again.
        let due = list.filter { self.pace.isDue(channelID: $0.id) || kept[$0.id] == nil }
        guard !due.isEmpty else {
            let refusal = DiscordReadRefusal.tooSoon(retryAfterSeconds: self.pace.secondsUntilDue(channelIDs: list.map(\.id)))
            self.logger.info("[discord-read] refused code=\(refusal.code, privacy: .public) served=last-reads")
            return self.result(list, from: kept, parameters: parameters, at: current, note: refusal.message + " " + Self.servedNote)
        }
        // Counted before the first request: Discord sees the requests whether
        // or not the pass completes.
        self.pace.recordPass()
        self.logger.info("[discord-read] pass started due=\(due.count) listed=\(list.count) limit=\(parameters.limit)")

        var note: String?
        var totalMessages = 0
        var freshChannels = 0
        for channel in due {
            self.pace.recordRead(channelID: channel.id)
            do {
                let messages = try await self.client.messages(in: channel, limit: parameters.limit)
                totalMessages += messages.count
                freshChannels += 1
                kept[channel.id] = .init(
                    id: channel.id, name: channel.name, server: channel.guildName, readAt: current,
                    messages: messages.map {
                        .init(id: $0.id, at: $0.timestampRFC3339, author: $0.author, text: $0.text, link: $0.link, attachments: $0.attachmentCount)
                    },
                    error: nil)
            } catch DiscordUserClientError.notConnected {
                self.logger.info("[discord-read] pass ended reason=not-connected")
                return .failure(code: "NOT_CONNECTED", message: "Discord did not accept the saved token. The person can save a new one under Connect accounts > Discord.")
            } catch let DiscordUserClientError.rateLimited(seconds) {
                self.pace.recordRateLimit()
                note = "Discord asked Operator to slow down (retry after \(seconds)s), so this pass stopped early and Discord reads are paused for a day. Report what was read; do not retry."
                self.logger.info("[discord-read] pass ended reason=rate-limited")
                break
            } catch DiscordUserClientError.notVisible {
                Self.fail(channel, in: &kept, at: current, error: "not visible to this account")
            } catch {
                Self.fail(channel, in: &kept, at: current, error: "could not be read")
            }
        }
        self.logger.info("[discord-read] pass complete fresh=\(freshChannels) messages=\(totalMessages)")
        self.cache.save(.init(channels: list.compactMap { kept[$0.id] }))
        if freshChannels < list.count, note == nil {
            note = "\(freshChannels) of \(list.count) channels were read now; the rest are shown from an earlier read. " + Self.servedNote
        }
        return self.result(list, from: kept, parameters: parameters, at: current, note: note)
    }

    /// A failed read never replaces a good one: the last successful read
    /// stays and is served, and the cooldown (recorded already) stops the
    /// channel being retried at once.
    private static func fail(_ channel: DiscordChannelEntry, in kept: inout [String: DiscordReadCache.Channel], at current: Date, error: String) {
        guard kept[channel.id]?.error != nil || kept[channel.id] == nil else { return }
        kept[channel.id] = .init(id: channel.id, name: channel.name, server: channel.guildName, readAt: current, messages: [], error: error)
    }

    private static let servedNote = "A channel with fromCache true is shown from an earlier read, at its readAt; say when it was read."

    private func result(_ list: [DiscordChannelEntry], from kept: [String: DiscordReadCache.Channel], parameters: Parameters, at current: Date, note: String?) -> GatewayNodeCommandResult {
        let formatter = ISO8601DateFormatter()
        var anyFresh = false
        let channels = list.map { entry -> [String: Any] in
            guard let channel = kept[entry.id] else {
                return ["id": entry.id, "channel": entry.name, "server": entry.guildName, "error": "not read: the pass stopped before it"]
            }
            let fromCache = channel.readAt < current
            anyFresh = anyFresh || (!fromCache && channel.error == nil)
            var object: [String: Any] = [
                "id": channel.id, "channel": channel.name, "server": channel.server,
                "readAt": formatter.string(from: channel.readAt), "fromCache": fromCache,
            ]
            if let error = channel.error {
                object["error"] = error
            } else {
                var messages = channel.messages
                if let since = parameters.since {
                    messages = messages.filter { Self.date($0.at).map { $0 > since } ?? true }
                }
                object["messages"] = messages.prefix(parameters.limit).map { message -> [String: Any] in
                    ["id": message.id, "at": message.at, "author": message.author, "text": message.text, "link": message.link, "attachments": message.attachments]
                }
            }
            return object
        }
        var payload: [String: Any] = [
            "channels": channels,
            "readAt": formatter.string(from: current),
            "fromCache": !anyFresh,
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
