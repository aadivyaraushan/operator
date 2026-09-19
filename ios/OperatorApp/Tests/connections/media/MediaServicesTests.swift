import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class MediaServicesTests: XCTestCase {
    func testYouTubeSearchUsesOneFixedV3RequestAndReturnsBoundedFields() async throws {
        let transport = MediaFixtureTransport(status: 200, body: #"{"nextPageToken":"not-exposed","items":[{"id":{"videoId":"dQw4w9WgXcQ"},"snippet":{"title":"A Title","channelTitle":"A Channel","description":"private detail"}}]}"#)
        let service = YouTubeSearchService(transport: transport, apiKey: { "configured-test-key" })

        let videos = try await service.search(query: "bicycle repair", limit: 5)

        XCTAssertEqual(videos, [.init(id: "dQw4w9WgXcQ", title: "A Title", channelTitle: "A Channel")])
        let captured = await transport.onlyRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "www.googleapis.com")
        XCTAssertEqual(request.url?.path, "/youtube/v3/search")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.value(for: "part"), "snippet")
        XCTAssertEqual(query?.value(for: "type"), "video")
        XCTAssertEqual(query?.value(for: "maxResults"), "5")
        XCTAssertEqual(query?.value(for: "q"), "bicycle repair")
        XCTAssertEqual(query?.value(for: "key"), "configured-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testYouTubeMissingKeyAndInvalidInputFailBeforeNetwork() async {
        let transport = MediaFixtureTransport(status: 200, body: "{}")
        let service = YouTubeSearchService(transport: transport, apiKey: { nil })
        await XCTAssertThrowsMediaError(try await service.search(query: "video", limit: 5), equals: YouTubeMediaError.setupRequired)
        await XCTAssertThrowsMediaError(try await service.search(query: " ", limit: 5), equals: YouTubeMediaError.invalidRequest)
        await XCTAssertThrowsMediaError(try await service.search(query: "video", limit: 6), equals: YouTubeMediaError.invalidRequest)
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testYouTubeOpenHandsOffExactWatchURLWithoutClaimingPlayback() async throws {
        let opener = MediaRecordingOpener()
        let service = YouTubeVideoOpenService(opener: opener)

        let receipt = try await service.open(videoID: "dQw4w9WgXcQ")

        XCTAssertEqual(opener.urls, [URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!])
        XCTAssertEqual(receipt.openedURL, opener.urls[0])
        XCTAssertFalse(receipt.actionCompleted)
        XCTAssertFalse(receipt.playbackVerified)

        await XCTAssertThrowsMediaError(try await service.open(videoID: "https://evil.invalid"), equals: YouTubeMediaError.invalidRequest)
        XCTAssertEqual(opener.urls.count, 1)
    }

    func testPodcastSearchParsesBoundedRSSItemsAndSafeEnclosures() async throws {
        let transport = MediaFixtureTransport(status: 200, body: Self.sampleFeed)
        let service = PodcastRSSService(transport: transport, publicHost: { _ in true })

        let episodes = try await service.search(
            feedURL: URL(string: "https://feeds.podcast.com/show.xml")!,
            query: "nested",
            limit: 3
        )

        XCTAssertEqual(episodes, [.init(
            guid: "ep-2",
            title: "Episode Two: Nested Paths",
            published: "Mon, 01 Jan 2024 12:00:00 GMT",
            enclosureURL: URL(string: "https://cdn.podcast.com/ep2.mp3")!,
            enclosureMIMEType: "audio/mpeg"
        )])
        let captured = await transport.onlyRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://feeds.podcast.com/show.xml")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/rss+xml, application/xml, text/xml")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPodcastRejectsPrivateOrUnresolvedFeedBeforeNetwork() async {
        let transport = MediaFixtureTransport(status: 200, body: Self.sampleFeed)
        let service = PodcastRSSService(transport: transport, publicHost: { _ in false })

        await XCTAssertThrowsMediaError(
            try await service.search(feedURL: URL(string: "https://127.0.0.1/feed.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.unsafeURL
        )
        await XCTAssertThrowsMediaError(
            try await service.search(feedURL: URL(string: "https://rebind.attacker.com/feed.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.unsafeURL
        )
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testPodcastRejectsExternalEntitiesOversizedFeedsAndRedirects() async {
        let doctype = #"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><rss><channel><item><title>&xxe;</title><guid>x</guid><enclosure url="https://cdn.podcast.com/x.mp3" length="1" type="audio/mpeg"/></item></channel></rss>"#
        let unsafeXML = PodcastRSSService(transport: MediaFixtureTransport(status: 200, body: doctype), publicHost: { _ in true })
        await XCTAssertThrowsMediaError(
            try await unsafeXML.search(feedURL: URL(string: "https://feeds.podcast.com/show.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.unsafeXML
        )

        let oversized = PodcastRSSService(transport: MediaFixtureTransport(status: 200, body: String(repeating: "x", count: 524_289)), publicHost: { _ in true })
        await XCTAssertThrowsMediaError(
            try await oversized.search(feedURL: URL(string: "https://feeds.podcast.com/show.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.invalidResponse
        )

        let redirectedTransport = MediaFixtureTransport(status: 302, body: "", headers: ["Location": "http://127.0.0.1/private"])
        let redirected = PodcastRSSService(transport: redirectedTransport, publicHost: { _ in true })
        await XCTAssertThrowsMediaError(
            try await redirected.search(feedURL: URL(string: "https://feeds.podcast.com/show.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.unavailable
        )
        let redirectRequestCount = await redirectedTransport.count()
        XCTAssertEqual(redirectRequestCount, 1)
    }

    func testPodcastCapsParsedItemsAndRejectsUnsafeEnclosures() async {
        let item = #"<item><title>Episode</title><guid>id</guid><enclosure url="https://cdn.podcast.com/e.mp3" length="1" type="audio/mpeg"/></item>"#
        let tooMany = "<rss><channel>" + String(repeating: item, count: 51) + "</channel></rss>"
        let capped = PodcastRSSService(transport: MediaFixtureTransport(status: 200, body: tooMany), publicHost: { _ in true })
        await XCTAssertThrowsMediaError(
            try await capped.search(feedURL: URL(string: "https://feeds.podcast.com/show.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.invalidResponse
        )

        let privateEnclosure = #"<rss><channel><item><title>Private</title><guid>private</guid><enclosure url="https://192.168.1.2/e.mp3" length="1" type="audio/mpeg"/></item></channel></rss>"#
        let unsafe = PodcastRSSService(transport: MediaFixtureTransport(status: 200, body: privateEnclosure), publicHost: { _ in true })
        await XCTAssertThrowsMediaError(
            try await unsafe.search(feedURL: URL(string: "https://feeds.podcast.com/show.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.unsafeURL
        )
    }

    func testPodcastRequiresBoundedNumericEnclosureLength() async {
        let missingLength = #"<rss><channel><item><title>Missing</title><guid>missing</guid><enclosure url="https://cdn.podcast.com/e.mp3" type="audio/mpeg"/></item></channel></rss>"#
        let missing = PodcastRSSService(transport: MediaFixtureTransport(status: 200, body: missingLength), publicHost: { _ in true })
        await XCTAssertThrowsMediaError(
            try await missing.search(feedURL: URL(string: "https://feeds.podcast.com/show.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.invalidResponse
        )

        let invalidLength = #"<rss><channel><item><title>Invalid</title><guid>invalid</guid><enclosure url="https://cdn.podcast.com/e.mp3" length="many" type="audio/mpeg"/></item></channel></rss>"#
        let invalid = PodcastRSSService(transport: MediaFixtureTransport(status: 200, body: invalidLength), publicHost: { _ in true })
        await XCTAssertThrowsMediaError(
            try await invalid.search(feedURL: URL(string: "https://feeds.podcast.com/show.xml")!, query: nil, limit: 5),
            equals: PodcastMediaError.invalidResponse
        )
    }

    func testPodcastEnclosureOpenIsOnlyAHandoff() async throws {
        let opener = MediaRecordingOpener()
        let service = PodcastEnclosureOpenService(opener: opener, publicHost: { _ in true })
        let episode = PodcastEpisode(
            guid: "ep-1",
            title: "Episode One",
            published: "Sun, 31 Dec 2023 12:00:00 GMT",
            enclosureURL: URL(string: "https://cdn.podcast.com/ep1.mp3")!,
            enclosureMIMEType: "audio/mpeg"
        )

        let receipt = try await service.open(episode)

        XCTAssertEqual(opener.urls, [episode.enclosureURL])
        XCTAssertEqual(receipt.openedURL, episode.enclosureURL)
        XCTAssertFalse(receipt.actionCompleted)
        XCTAssertFalse(receipt.playbackVerified)

        let privateEpisode = PodcastEpisode(guid: "x", title: "Private", published: "", enclosureURL: URL(string: "https://localhost/e.mp3")!, enclosureMIMEType: "audio/mpeg")
        await XCTAssertThrowsMediaError(try await service.open(privateEpisode), equals: PodcastMediaError.unsafeURL)
        XCTAssertEqual(opener.urls.count, 1)
    }

    func testMediaNodeUsesFourFixedStrictCommandSchemas() async {
        let transport = MediaFixtureTransport(status: 200, body: Self.sampleFeed)
        let opener = MediaRecordingOpener()
        let service = ForegroundMediaNodeService(
            youtubeSearch: YouTubeSearchService(transport: MediaFixtureTransport(status: 200, body: #"{"items":[]}"#), apiKey: { "key" }),
            podcastRSS: PodcastRSSService(transport: transport, publicHost: { _ in true }),
            opener: opener,
            publicHost: { _ in true },
            isAppActive: { true }
        )

        let unsupported = await service.handleNodeCommand("media.open", paramsJSON: "{}", timeoutMilliseconds: nil)
        XCTAssertEqual(
            unsupported,
            .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support media.open")
        )
        let invalidYouTube = await service.handleNodeCommand("youtube.search", paramsJSON: #"{"query":"x","extra":true}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(
            invalidYouTube,
            .failure(code: "INVALID_REQUEST", message: "YouTube search parameters were invalid")
        )
        let arbitraryEnclosure = await service.handleNodeCommand("podcasts.open", paramsJSON: #"{"feedURL":"https://feeds.podcast.com/show.xml","episodeID":"ep-1","enclosureURL":"https://cdn.podcast.com/ep1.mp3"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(
            arbitraryEnclosure,
            .failure(code: "INVALID_REQUEST", message: "Podcast open parameters were invalid")
        )
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testMediaNodeSearchesYouTubeAndReturnsOnlyBoundedResultFields() async throws {
        let transport = MediaFixtureTransport(status: 200, body: #"{"nextPageToken":"hidden","items":[{"id":{"videoId":"dQw4w9WgXcQ"},"snippet":{"title":"A Title","channelTitle":"A Channel","description":"hidden"}}]}"#)
        let service = ForegroundMediaNodeService(
            youtubeSearch: YouTubeSearchService(transport: transport, apiKey: { "configured-test-key" }),
            podcastRSS: PodcastRSSService(transport: MediaFixtureTransport(status: 500, body: ""), publicHost: { _ in true }),
            opener: MediaRecordingOpener(),
            publicHost: { _ in true },
            isAppActive: { true }
        )

        let result = await service.handleNodeCommand("youtube.search", paramsJSON: #"{"query":"repair","limit":1}"#, timeoutMilliseconds: 1_000)
        guard case let .success(payloadJSON) = result else { return XCTFail("Expected success") }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
        XCTAssertEqual(payload["count"] as? Int, 1)
        let videos = try XCTUnwrap(payload["videos"] as? [[String: Any]])
        XCTAssertEqual(Set(videos[0].keys), ["id", "title", "channelTitle"])
        XCTAssertEqual(videos[0]["id"] as? String, "dQw4w9WgXcQ")
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testMediaNodePodcastOpenResolvesExactEpisodeFromFeed() async throws {
        let transport = MediaFixtureTransport(status: 200, body: Self.sampleFeed)
        let opener = MediaRecordingOpener()
        let service = ForegroundMediaNodeService(
            youtubeSearch: YouTubeSearchService(transport: MediaFixtureTransport(status: 500, body: ""), apiKey: { nil }),
            podcastRSS: PodcastRSSService(transport: transport, publicHost: { _ in true }),
            opener: opener,
            publicHost: { _ in true },
            isAppActive: { true }
        )

        let result = await service.handleNodeCommand(
            "podcasts.open",
            paramsJSON: #"{"feedURL":"https://feeds.podcast.com/show.xml","episodeID":"ep-1"}"#,
            timeoutMilliseconds: 1_000
        )

        guard case let .success(payloadJSON) = result else { return XCTFail("Expected success") }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
        XCTAssertEqual(payload["opened"] as? Bool, true)
        XCTAssertEqual(payload["episodeID"] as? String, "ep-1")
        XCTAssertEqual(payload["openedURL"] as? String, "https://cdn.podcast.com/ep1.mp3")
        XCTAssertEqual(payload["actionCompleted"] as? Bool, false)
        XCTAssertEqual(payload["playbackVerified"] as? Bool, false)
        XCTAssertEqual(opener.urls, [URL(string: "https://cdn.podcast.com/ep1.mp3")!])
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testMediaNodeGuardsAppActivityCancellationAndMissingYouTubeSetup() async {
        let inactive = ForegroundMediaNodeService(
            youtubeSearch: YouTubeSearchService(transport: MediaFixtureTransport(status: 200, body: "{}"), apiKey: { nil }),
            podcastRSS: PodcastRSSService(transport: MediaFixtureTransport(status: 200, body: Self.sampleFeed), publicHost: { _ in true }),
            opener: MediaRecordingOpener(),
            publicHost: { _ in true },
            isAppActive: { false }
        )
        let inactiveResult = await inactive.handleNodeCommand("youtube.search", paramsJSON: #"{"query":"x"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(
            inactiveResult,
            .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use media commands")
        )

        let active = ForegroundMediaNodeService(opener: MediaRecordingOpener(), isAppActive: { true })
        let setupResult = await active.handleNodeCommand("youtube.search", paramsJSON: #"{"query":"x"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(
            setupResult,
            .failure(code: "YOUTUBE_SETUP_REQUIRED", message: "Configure a YouTube API key in Operator before searching")
        )

        let cancelled = Task { @MainActor in
            await active.handleNodeCommand("podcasts.search", paramsJSON: #"{"feedURL":"https://feeds.podcast.com/show.xml"}"#, timeoutMilliseconds: nil)
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertEqual(
            cancelledResult,
            .failure(code: "CANCELLED", message: "The media command was cancelled")
        )
    }

    func testInAppMediaOpenerChecksSafePublicURLBeforePresentation() async {
        var presented: [URL] = []
        let opener = InAppMediaOpener(
            isAppActive: { true },
            publicHost: { _ in true },
            present: { url in presented.append(url); return true }
        )
        let watchURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let opened = await opener.open(watchURL)
        XCTAssertTrue(opened)
        XCTAssertEqual(presented, [watchURL])

        let blocked = URL(string: "https://127.0.0.1/private.mp3")!
        let openedBlocked = await opener.open(blocked)
        XCTAssertFalse(openedBlocked)
        XCTAssertEqual(presented, [watchURL])
    }

    func testPublicMediaTransportHasNoAmbientStateAndBoundsWhileReading() {
        let configuration = PublicMediaHTTPTransport.configuration(timeout: 20)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        var buffer = PublicMediaResponseBuffer(limit: 3)
        XCTAssertTrue(buffer.append(Data([1, 2])))
        XCTAssertFalse(buffer.append(Data([3, 4])))
        XCTAssertEqual(buffer.data, Data([1, 2]))
    }

    func testForegroundRouterSendsOnlyMediaCommandsToMediaHandler() async {
        let other = MediaNodeRecordingHandler()
        let media = MediaNodeRecordingHandler()
        let router = ForegroundNodeCommandRouter(
            location: other,
            calendar: other,
            messages: other,
            maps: other,
            handoff: other,
            whatsapp: other,
            whatsappCompose: other,
            accounts: other,
            accountWrite: other,
            media: media,
            notion: other
        )

        for command in ForegroundMediaNodeService.commands {
            _ = await router.handleNodeCommand(command, paramsJSON: "{}", timeoutMilliseconds: 1_000)
        }

        XCTAssertEqual(media.commands, ForegroundMediaNodeService.commands)
        XCTAssertTrue(other.commands.isEmpty)
    }

    func testMediaNodeTimeoutCancelsSlowFetchBeforeAnyOpen() async {
        let transport = DelayedMediaTransport()
        let opener = MediaRecordingOpener()
        let service = ForegroundMediaNodeService(
            youtubeSearch: YouTubeSearchService(transport: MediaFixtureTransport(status: 500, body: ""), apiKey: { nil }),
            podcastRSS: PodcastRSSService(transport: transport, publicHost: { _ in true }),
            opener: opener,
            publicHost: { _ in true },
            isAppActive: { true }
        )
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await transport.resume(status: 200, body: Self.sampleFeed)
        }

        let result = await service.handleNodeCommand(
            "podcasts.open",
            paramsJSON: #"{"feedURL":"https://feeds.podcast.com/show.xml","episodeID":"ep-1"}"#,
            timeoutMilliseconds: 50
        )

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "The media command timed out before opening anything"))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(opener.urls.isEmpty)
    }

    private static let sampleFeed = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Sample Show</title>
      <item><title>Episode Two: Nested Paths</title><guid>ep-2</guid><pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate><enclosure url="https://cdn.podcast.com/ep2.mp3" length="2048" type="audio/mpeg"/></item>
      <item><title>Episode One: Hello Feed</title><guid>ep-1</guid><pubDate>Sun, 31 Dec 2023 12:00:00 GMT</pubDate><enclosure url="https://cdn.podcast.com/ep1.mp3" length="1024" type="audio/mpeg"/></item>
      <item><title>Not playable</title><guid>text-only</guid></item>
    </channel></rss>
    """#
}

private actor MediaFixtureTransport: PhoneHTTPTransport {
    private let status: Int
    private let body: String
    private let headers: [String: String]
    private var requests: [URLRequest] = []

    init(status: Int, body: String, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: self.headers)!)
    }

    func onlyRequest() -> URLRequest? { self.requests.count == 1 ? self.requests[0] : nil }
    func count() -> Int { self.requests.count }
}

private actor DelayedMediaTransport: PhoneHTTPTransport {
    private var continuation: CheckedContinuation<(Data, URLResponse), Never>?
    private var requestURL: URL?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requestURL = request.url
        return await withCheckedContinuation { self.continuation = $0 }
    }

    func resume(status: Int, body: String) {
        guard let continuation, let requestURL else { return }
        self.continuation = nil
        continuation.resume(returning: (
            Data(body.utf8),
            HTTPURLResponse(url: requestURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        ))
    }
}

@MainActor
private final class MediaRecordingOpener: AppHandoffOpener {
    var urls: [URL] = []
    var result = true
    func open(_ url: URL) async -> Bool { self.urls.append(url); return self.result }
}

@MainActor
private final class MediaNodeRecordingHandler: GatewayNodeCommandHandler {
    var commands: [String] = []

    func handleNodeCommand(
        _ command: String,
        paramsJSON _: String?,
        timeoutMilliseconds _: Int?
    ) async -> GatewayNodeCommandResult {
        self.commands.append(command)
        return .success(payloadJSON: "{}")
    }
}

private extension Array where Element == URLQueryItem {
    func value(for name: String) -> String? { self.first { $0.name == name }?.value }
}

@MainActor
private func XCTAssertThrowsMediaError<T: Sendable, E: Error & Equatable & Sendable>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected media error", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
    }
}
