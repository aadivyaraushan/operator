import Foundation
import OperatorCore
import OSLog

@MainActor
final class ForegroundMediaNodeService: GatewayNodeCommandHandler {
    static let commands = ["youtube.search", "youtube.open", "podcasts.search", "podcasts.open"]

    private let youtubeSearch: YouTubeSearchService
    private let youtubeOpen: YouTubeVideoOpenService
    private let podcastRSS: PodcastRSSService
    private let podcastOpen: PodcastEnclosureOpenService
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "media-node")

    init(
        youtubeSearch: YouTubeSearchService,
        podcastRSS: PodcastRSSService,
        opener: any AppHandoffOpener,
        publicHost: @escaping @Sendable (String) async -> Bool = PublicMediaURLPolicy.hostResolvesOnlyToPublicAddresses,
        isAppActive: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.youtubeSearch = youtubeSearch
        self.youtubeOpen = YouTubeVideoOpenService(opener: opener)
        self.podcastRSS = podcastRSS
        self.podcastOpen = PodcastEnclosureOpenService(opener: opener, publicHost: publicHost)
        self.isAppActive = isAppActive
    }

    convenience init(
        apiKey: @escaping @Sendable () async throws -> String? = { nil },
        opener: any AppHandoffOpener,
        isAppActive: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.init(
            youtubeSearch: YouTubeSearchService(apiKey: apiKey),
            podcastRSS: PodcastRSSService(),
            opener: opener,
            isAppActive: isAppActive
        )
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?
    ) async -> GatewayNodeCommandResult {
        self.logger.info("[media-node] input command_bytes=\(command.utf8.count) params_bytes=\(paramsJSON?.utf8.count ?? 0)")
        guard Self.commands.contains(command) else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(String(command.prefix(128)))")
        }
        guard !Task.isCancelled else { return Self.cancelled }
        guard self.isAppActive() else {
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use media commands")
        }

        let requested = min(max(timeoutMilliseconds ?? 30_000, 1), 30_000)
        let responseMargin = min(250, max(1, requested / 10))
        let workMilliseconds = max(1, requested - responseMargin)
        return await MediaCommandDeadline().run(milliseconds: workMilliseconds) { [weak self] in
            guard let self else {
                return .failure(code: "CANCELLED", message: "The media command was cancelled")
            }
            return await self.dispatch(command, paramsJSON: paramsJSON)
        }
    }

    private func dispatch(_ command: String, paramsJSON: String?) async -> GatewayNodeCommandResult {
        switch command {
        case "youtube.search":
            return await self.searchYouTube(paramsJSON)
        case "youtube.open":
            return await self.openYouTube(paramsJSON)
        case "podcasts.search":
            return await self.searchPodcasts(paramsJSON)
        case "podcasts.open":
            return await self.openPodcast(paramsJSON)
        default:
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support this command")
        }
    }

    private func searchYouTube(_ json: String?) async -> GatewayNodeCommandResult {
        guard let raw = Self.object(json, allowedKeys: ["query", "limit"]),
              let query = raw["query"] as? String,
              let limit = Self.integer(raw["limit"], default: 5),
              (1 ... 5).contains(limit)
        else { return .failure(code: "INVALID_REQUEST", message: "YouTube search parameters were invalid") }
        do {
            let videos = try await self.youtubeSearch.search(query: query, limit: limit)
            guard self.canReturnResult else { return self.guardFailure }
            return Self.encoded([
                "count": videos.count,
                "videos": videos.map { ["id": $0.id, "title": $0.title, "channelTitle": $0.channelTitle] },
            ], fallback: "YOUTUBE_UNAVAILABLE")
        } catch {
            return Self.youtubeFailure(error)
        }
    }

    private func openYouTube(_ json: String?) async -> GatewayNodeCommandResult {
        guard let raw = Self.object(json, allowedKeys: ["videoID"]),
              raw.count == 1,
              let videoID = raw["videoID"] as? String
        else { return .failure(code: "INVALID_REQUEST", message: "YouTube open parameters were invalid") }
        guard self.canReturnResult else { return self.guardFailure }
        do {
            let receipt = try await self.youtubeOpen.open(videoID: videoID)
            guard self.canReturnResult else { return self.guardFailure }
            return Self.opened(receipt, extra: ["videoID": videoID])
        } catch {
            return Self.youtubeFailure(error)
        }
    }

    private func searchPodcasts(_ json: String?) async -> GatewayNodeCommandResult {
        guard let raw = Self.object(json, allowedKeys: ["feedURL", "query", "limit"]),
              let feedText = raw["feedURL"] as? String,
              let feedURL = URL(string: feedText),
              raw["query"] == nil || raw["query"] is String,
              let limit = Self.integer(raw["limit"], default: 10),
              (1 ... 10).contains(limit)
        else { return .failure(code: "INVALID_REQUEST", message: "Podcast search parameters were invalid") }
        do {
            let episodes = try await self.podcastRSS.search(
                feedURL: feedURL,
                query: raw["query"] as? String,
                limit: limit
            )
            guard self.canReturnResult else { return self.guardFailure }
            return Self.encoded([
                "count": episodes.count,
                "episodes": episodes.map {
                    [
                        "episodeID": $0.guid,
                        "title": $0.title,
                        "published": $0.published,
                        "enclosureType": $0.enclosureMIMEType,
                    ]
                },
            ], fallback: "PODCAST_UNAVAILABLE")
        } catch {
            return Self.podcastFailure(error)
        }
    }

    private func openPodcast(_ json: String?) async -> GatewayNodeCommandResult {
        guard let raw = Self.object(json, allowedKeys: ["feedURL", "episodeID"]),
              raw.count == 2,
              let feedText = raw["feedURL"] as? String,
              let feedURL = URL(string: feedText),
              let episodeID = raw["episodeID"] as? String
        else { return .failure(code: "INVALID_REQUEST", message: "Podcast open parameters were invalid") }
        do {
            guard let episode = try await self.podcastRSS.resolve(feedURL: feedURL, episodeID: episodeID) else {
                return .failure(code: "EPISODE_NOT_FOUND", message: "That episode was not found in the current feed")
            }
            guard self.canReturnResult else { return self.guardFailure }
            let receipt = try await self.podcastOpen.open(episode)
            guard self.canReturnResult else { return self.guardFailure }
            return Self.opened(receipt, extra: ["episodeID": episode.guid])
        } catch {
            return Self.podcastFailure(error)
        }
    }

    private var canReturnResult: Bool { !Task.isCancelled && self.isAppActive() }

    private var guardFailure: GatewayNodeCommandResult {
        Task.isCancelled
            ? Self.cancelled
            : .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use media commands")
    }

    private static let cancelled = GatewayNodeCommandResult.failure(
        code: "CANCELLED",
        message: "The media command was cancelled"
    )

    private static func object(_ text: String?, allowedKeys: Set<String>) -> [String: Any]? {
        guard let text,
              text.utf8.count <= 8_192,
              let raw = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(raw.keys).isSubset(of: allowedKeys)
        else { return nil }
        return raw
    }

    private static func integer(_ value: Any?, default fallback: Int) -> Int? {
        guard let value else { return fallback }
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max)
        else { return nil }
        return number.intValue
    }

    private static func opened(_ receipt: MediaOpenReceipt, extra: [String: Any]) -> GatewayNodeCommandResult {
        var payload = extra
        payload["opened"] = true
        payload["openedURL"] = receipt.openedURL.absoluteString
        payload["actionCompleted"] = receipt.actionCompleted
        payload["playbackVerified"] = receipt.playbackVerified
        return self.encoded(payload, fallback: "OPEN_FAILED")
    }

    private static func encoded(_ object: [String: Any], fallback: String) -> GatewayNodeCommandResult {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= 65_536
        else { return .failure(code: fallback, message: "The media response was unavailable") }
        return .success(payloadJSON: String(decoding: data, as: UTF8.self))
    }

    private static func youtubeFailure(_ error: Error) -> GatewayNodeCommandResult {
        if error is CancellationError { return self.cancelled }
        guard let error = error as? YouTubeMediaError else {
            return .failure(code: "YOUTUBE_UNAVAILABLE", message: "YouTube is unavailable")
        }
        switch error {
        case .invalidRequest:
            return .failure(code: "INVALID_REQUEST", message: "YouTube parameters were invalid")
        case .setupRequired:
            return .failure(code: "YOUTUBE_SETUP_REQUIRED", message: "Configure a YouTube API key in Operator before searching")
        case .permissionDenied:
            return .failure(code: "YOUTUBE_API_DENIED", message: "The configured YouTube API key was denied")
        case .rateLimited:
            return .failure(code: "RATE_LIMITED", message: "YouTube search is temporarily rate limited")
        case .openFailed:
            return .failure(code: "OPEN_FAILED", message: "The YouTube page could not be opened")
        case .unavailable, .invalidResponse:
            return .failure(code: "YOUTUBE_UNAVAILABLE", message: "YouTube is unavailable")
        }
    }

    private static func podcastFailure(_ error: Error) -> GatewayNodeCommandResult {
        if error is CancellationError { return self.cancelled }
        guard let error = error as? PodcastMediaError else {
            return .failure(code: "PODCAST_UNAVAILABLE", message: "The podcast feed is unavailable")
        }
        switch error {
        case .invalidRequest:
            return .failure(code: "INVALID_REQUEST", message: "Podcast parameters were invalid")
        case .unsafeURL:
            return .failure(code: "UNSAFE_URL", message: "Only public HTTPS podcast URLs are allowed")
        case .unsafeXML, .invalidResponse:
            return .failure(code: "PODCAST_FEED_INVALID", message: "The podcast feed was invalid")
        case .unavailable:
            return .failure(code: "PODCAST_UNAVAILABLE", message: "The podcast feed is unavailable")
        case .openFailed:
            return .failure(code: "OPEN_FAILED", message: "The podcast episode could not be opened")
        }
    }
}

@MainActor
private final class MediaCommandDeadline {
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<GatewayNodeCommandResult, Never>?

    func run(
        milliseconds: Int,
        operation: @escaping @MainActor @Sendable () async -> GatewayNodeCommandResult
    ) async -> GatewayNodeCommandResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    self.finish(.failure(code: "CANCELLED", message: "The media command was cancelled"))
                    return
                }
                self.work = Task { [weak self] in
                    let result = await operation()
                    self?.finish(result)
                }
                self.timeout = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(
                        code: "TIMEOUT",
                        message: "The media command timed out before opening anything"
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(code: "CANCELLED", message: "The media command was cancelled"))
            }
        }
    }

    private func finish(_ result: GatewayNodeCommandResult) {
        guard let continuation else { return }
        self.continuation = nil
        self.work?.cancel()
        self.timeout?.cancel()
        continuation.resume(returning: result)
    }
}
