import Foundation
import OSLog

/// One announcement channel the owner chose. The id is what Discord needs;
/// the names are what the owner and the model see.
struct DiscordChannelEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var guildName: String
    var guildID: String
}

/// One message as the model sees it. Author is a display name only, never an
/// id; the link is the message's own, so the owner can open it in Discord.
struct DiscordAnnouncement: Equatable, Sendable {
    let id: String
    let timestampRFC3339: String
    let author: String
    let text: String
    let link: String
    let attachmentCount: Int
}

enum DiscordUserClientError: Error, Equatable, Sendable {
    /// 401: the token is wrong or the account is gone.
    case notConnected
    /// 403 or 404: not a member of that server, or the channel is not visible.
    case notVisible
    /// 429; Discord asked for a pause. The client never retries on its own.
    case rateLimited(retryAfterSeconds: Int)
    case invalidResponse
    case unavailable
}

/// Discord's REST API with the owner's own login. Only GETs, only the three
/// routes below, never the gateway websocket. The headers are the shape the
/// official iOS app sends; a request that looks like a script is the one
/// thing about a quiet reader that a detector could key on.
actor DiscordUserClient {
    static let base = URL(string: "https://discord.com/api/v10")!
    static let maxBodyBytes = 1_048_576
    static let textLimit = 2_000

    private let transport: any PhoneHTTPTransport
    private let token: @Sendable () async throws -> String?
    private let logger = Logger(subsystem: "app.operator.ios", category: "discord-client")

    init(transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport(), token: @escaping @Sendable () async throws -> String?) {
        self.transport = transport
        self.token = token
    }

    /// The signed-in account's handle. Used once, when a token is saved, to
    /// prove it works; never on a read pass.
    func me() async throws -> String {
        let object = try await self.getObject(path: "/users/@me")
        guard let name = object["username"] as? String, !name.isEmpty else { throw DiscordUserClientError.invalidResponse }
        return name
    }

    /// Resolves a pasted channel into an entry with its names. Two requests,
    /// once, at setup.
    func channel(id: String) async throws -> DiscordChannelEntry {
        guard Self.isSnowflake(id) else { throw DiscordUserClientError.invalidResponse }
        let channel = try await self.getObject(path: "/channels/\(id)")
        guard let name = channel["name"] as? String, let guildID = channel["guild_id"] as? String, Self.isSnowflake(guildID) else {
            throw DiscordUserClientError.invalidResponse
        }
        let guild = try await self.getObject(path: "/guilds/\(guildID)")
        let guildName = (guild["name"] as? String) ?? guildID
        return DiscordChannelEntry(id: id, name: String(name.prefix(100)), guildName: String(guildName.prefix(100)), guildID: guildID)
    }

    /// The newest `limit` messages in a channel, newest first, as Discord
    /// returns them. One request.
    func messages(in channel: DiscordChannelEntry, limit: Int) async throws -> [DiscordAnnouncement] {
        guard Self.isSnowflake(channel.id) else { throw DiscordUserClientError.invalidResponse }
        let bounded = max(1, min(limit, 50))
        let array = try await self.getArray(path: "/channels/\(channel.id)/messages?limit=\(bounded)")
        return array.prefix(bounded).compactMap { Self.announcement(from: $0, channel: channel) }
    }

    // MARK: Wire

    static func isSnowflake(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{15,22}$"#, options: .regularExpression) != nil
    }

    static func announcement(from object: [String: Any], channel: DiscordChannelEntry) -> DiscordAnnouncement? {
        guard let id = object["id"] as? String, Self.isSnowflake(id),
              let timestamp = object["timestamp"] as? String, timestamp.utf8.count <= 64
        else { return nil }
        let author = object["author"] as? [String: Any]
        let name = (author?["global_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (author?["username"] as? String) ?? "unknown"
        var parts: [String] = []
        if let content = object["content"] as? String, !content.isEmpty { parts.append(content) }
        // Announcements are often an embed with no plain content.
        for embed in (object["embeds"] as? [[String: Any]] ?? []).prefix(5) {
            let title = embed["title"] as? String ?? ""
            let description = embed["description"] as? String ?? ""
            let line = [title, description].filter { !$0.isEmpty }.joined(separator: " - ")
            if !line.isEmpty { parts.append("[embed] \(line)") }
        }
        let attachments = (object["attachments"] as? [Any])?.count ?? 0
        let text = String(parts.joined(separator: "\n").prefix(Self.textLimit))
        return DiscordAnnouncement(
            id: id, timestampRFC3339: timestamp, author: String(name.prefix(80)), text: text,
            link: "https://discord.com/channels/\(channel.guildID)/\(channel.id)/\(id)",
            attachmentCount: attachments)
    }

    private func getObject(path: String) async throws -> [String: Any] {
        let data = try await self.get(path: path)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw DiscordUserClientError.invalidResponse }
        return object
    }

    private func getArray(path: String) async throws -> [[String: Any]] {
        let data = try await self.get(path: path)
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw DiscordUserClientError.invalidResponse }
        return array
    }

    private func get(path: String) async throws -> Data {
        guard let token = try await self.token(), Self.plausibleToken(token) else { throw DiscordUserClientError.notConnected }
        guard let url = URL(string: Self.base.absoluteString + path) else { throw DiscordUserClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // A user token goes bare, not as a Bearer.
        request.setValue(token, forHTTPHeaderField: "Authorization")
        for (field, value) in Self.clientHeaders { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await self.transport.data(for: request) } catch { throw DiscordUserClientError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw DiscordUserClientError.unavailable }
        self.logger.info("[discord-client] response route=\(Self.route(path), privacy: .public) status=\(http.statusCode) bytes=\(data.count)")
        switch http.statusCode {
        case 200: break
        case 401: throw DiscordUserClientError.notConnected
        case 403, 404: throw DiscordUserClientError.notVisible
        case 429:
            let header = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw DiscordUserClientError.rateLimited(retryAfterSeconds: Int(min(max(header, 1), 86_400).rounded(.up)))
        default: throw DiscordUserClientError.unavailable
        }
        guard data.count <= Self.maxBodyBytes else { throw DiscordUserClientError.invalidResponse }
        return data
    }

    /// Logged instead of the path, so a channel id never reaches the log.
    private static func route(_ path: String) -> String {
        if path.hasPrefix("/users/@me") { return "me" }
        if path.hasPrefix("/guilds/") { return "guild" }
        if path.contains("/messages") { return "messages" }
        return "channel"
    }

    static func plausibleToken(_ token: String) -> Bool {
        (30...400).contains(token.utf8.count) && !token.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    /// What the official iOS client sends. The build number and version move
    /// with each app release; these are from the September 2026 App Store build.
    static let clientHeaders: [String: String] = {
        let properties: [String: Any] = [
            "os": "iOS", "browser": "Discord iOS", "device": "iPhone18,3", "system_locale": "en-US",
            "client_version": "297.0", "release_channel": "stable", "client_build_number": 92_611,
            "os_version": "26.0", "browser_user_agent": "", "client_event_source": NSNull(),
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys]))?.base64EncodedString() ?? ""
        return [
            "User-Agent": "Discord-iOS/92611 (iPhone; iOS 26.0; Scale/3.00)",
            "X-Super-Properties": encoded,
            "X-Discord-Locale": "en-US",
            "X-Discord-Timezone": TimeZone.current.identifier,
            "Accept": "*/*",
        ]
    }()
}
