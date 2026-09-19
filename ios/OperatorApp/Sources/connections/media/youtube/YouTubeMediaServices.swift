import Foundation
import OSLog

struct YouTubeVideo: Equatable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
}

enum YouTubeMediaError: Error, Equatable, Sendable {
    case invalidRequest
    case setupRequired
    case permissionDenied
    case rateLimited(retryAfterSeconds: Int)
    case unavailable
    case invalidResponse
    case openFailed
}

actor YouTubeSearchService {
    private let transport: any PhoneHTTPTransport
    private let apiKey: @Sendable () async throws -> String?
    private let logger = Logger(subsystem: "app.operator.ios", category: "youtube-media")

    init(
        transport: any PhoneHTTPTransport = PublicMediaHTTPTransport(maxResponseBytes: 262_144),
        apiKey: @escaping @Sendable () async throws -> String?
    ) {
        self.transport = transport
        self.apiKey = apiKey
    }

    func search(query: String, limit: Int) async throws -> [YouTubeVideo] {
        self.logger.info("[youtube-media] search input query_bytes=\(query.utf8.count) limit=\(limit)")
        guard (1 ... 5).contains(limit), Self.validText(query, maxBytes: 200, required: true) else {
            self.logger.error("[youtube-media] search refused error_code=invalid_request")
            throw YouTubeMediaError.invalidRequest
        }
        let configuredKey: String?
        do {
            configuredKey = try await self.apiKey()
        } catch {
            self.logger.error("[youtube-media] search refused error_code=setup_required")
            throw YouTubeMediaError.setupRequired
        }
        guard let key = configuredKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              key.utf8.count <= 4_096,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            self.logger.error("[youtube-media] search refused error_code=setup_required")
            throw YouTubeMediaError.setupRequired
        }
        try Task.checkCancellation()

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: String(limit)),
            URLQueryItem(name: "key", value: key),
        ]
        guard let url = components.url else { throw YouTubeMediaError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        self.logger.info("[youtube-media] search request method=GET path=/youtube/v3/search limit=\(limit)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.transport.data(for: request)
        } catch is CancellationError {
            self.logger.info("[youtube-media] search cancelled")
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            self.logger.info("[youtube-media] search cancelled")
            throw error
        } catch {
            self.logger.error("[youtube-media] search failed error_code=unavailable")
            throw YouTubeMediaError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw YouTubeMediaError.unavailable }
        self.logger.info("[youtube-media] search response status=\(http.statusCode) bytes=\(data.count)")
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw YouTubeMediaError.permissionDenied
        case 429:
            let parsed = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
            throw YouTubeMediaError.rateLimited(retryAfterSeconds: min(max(parsed, 1), 86_400))
        default:
            throw YouTubeMediaError.unavailable
        }
        guard data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]],
              items.count <= limit
        else { throw YouTubeMediaError.invalidResponse }

        var videos: [YouTubeVideo] = []
        for item in items {
            guard let id = (item["id"] as? [String: Any])?["videoId"] as? String,
                  Self.matches(id, pattern: #"^[A-Za-z0-9_-]{11}$"#),
                  let snippet = item["snippet"] as? [String: Any],
                  let title = snippet["title"] as? String,
                  Self.validText(title, maxBytes: 512, required: true),
                  let channel = snippet["channelTitle"] as? String,
                  Self.validText(channel, maxBytes: 256, required: false)
            else { throw YouTubeMediaError.invalidResponse }
            videos.append(.init(id: id, title: title, channelTitle: channel))
        }
        self.logger.info("[youtube-media] search complete result_count=\(videos.count)")
        return videos
    }

    private static func validText(_ value: String, maxBytes: Int, required: Bool) -> Bool {
        guard value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        return !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

@MainActor
final class YouTubeVideoOpenService {
    private let opener: any AppHandoffOpener
    private let logger = Logger(subsystem: "app.operator.ios", category: "youtube-media")

    init(opener: any AppHandoffOpener) {
        self.opener = opener
    }

    func open(videoID: String) async throws -> MediaOpenReceipt {
        guard videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")
        else {
            self.logger.error("[youtube-media] open refused error_code=invalid_request")
            throw YouTubeMediaError.invalidRequest
        }
        self.logger.info("[youtube-media] open request video_id_bytes=\(videoID.utf8.count)")
        guard await self.opener.open(url) else {
            self.logger.error("[youtube-media] open failed error_code=open_failed")
            throw YouTubeMediaError.openFailed
        }
        self.logger.info("[youtube-media] open complete action_completed=false playback_verified=false")
        return .init(openedURL: url, actionCompleted: false, playbackVerified: false)
    }
}
