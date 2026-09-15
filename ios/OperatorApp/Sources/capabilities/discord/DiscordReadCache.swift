import Foundation

/// The last read of each listed channel, kept so a channel inside its
/// cooldown can still answer. The ration is about what Discord sees; serving
/// a read again costs Discord nothing, so a second "what did I miss" ten
/// minutes after the first gets the same read, dated, instead of a refusal.
struct DiscordReadCache: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable {
        let id: String
        let at: String
        let author: String
        let text: String
        let link: String
        let attachments: Int
    }

    struct Channel: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let server: String
        /// When this channel was read. Each channel carries its own: a pass
        /// reads only the channels that are due, and keeps the rest.
        let readAt: Date
        /// Newest first, as Discord returned them. Empty when `error` is set.
        let messages: [Message]
        let error: String?
    }

    let channels: [Channel]
}

protocol DiscordReadCacheStore: AnyObject, Sendable {
    func load() -> DiscordReadCache?
    func save(_ cache: DiscordReadCache)
}

/// One JSON file beside the runtime's state. Not UserDefaults: twenty
/// channels' worth is a quarter megabyte, and defaults are read whole.
final class FileDiscordReadCacheStore: DiscordReadCacheStore, @unchecked Sendable {
    private let fileURL: URL

    init(supportDirectory: URL) {
        self.fileURL = supportDirectory.appendingPathComponent("Operator/discord-last-pass.json")
    }

    func load() -> DiscordReadCache? {
        guard let data = try? Data(contentsOf: self.fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiscordReadCache.self, from: data)
    }

    func save(_ cache: DiscordReadCache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
