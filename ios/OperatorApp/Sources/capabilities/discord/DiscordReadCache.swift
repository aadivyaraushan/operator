import Foundation

/// The last pass, kept so a refused pass can still answer. The ration is
/// about what Discord sees; serving the previous read costs Discord nothing,
/// so a second "what did I miss" in the same afternoon gets the morning's
/// read, dated, instead of a bare refusal.
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
        /// Newest first, as Discord returned them. Empty when `error` is set.
        let messages: [Message]
        let error: String?
    }

    let readAt: Date
    /// The per-channel limit the pass was made with; a later ask for more
    /// cannot be answered from here.
    let limit: Int
    let channels: [Channel]
    /// The pass's own note (a 429 ended it early), carried with the data.
    let note: String?
}

protocol DiscordReadCacheStore: AnyObject, Sendable {
    func load() -> DiscordReadCache?
    func save(_ cache: DiscordReadCache)
}

/// One JSON file beside the runtime's state. Not UserDefaults: a pass over
/// twenty channels is a quarter megabyte, and defaults are read whole.
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
