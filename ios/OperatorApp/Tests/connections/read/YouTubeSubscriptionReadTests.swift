import Foundation
import XCTest
@testable import OperatorApp

/// "What is the latest video on my subscriptions" has to be one call, so the
/// feed read lists the subscriptions and fans out over their uploads itself.
/// These pin the requests it makes, the seven-day window, and the row shape.
final class YouTubeSubscriptionReadTests: XCTestCase {
    private static let now = ISO8601DateFormatter().date(from: "2026-09-18T12:00:00Z")!

    private static let subscriptions = #"""
    {"items":[
      {"snippet":{"title":"Chan A","description":"desc a","publishedAt":"2026-01-01T00:00:00Z","resourceId":{"channelId":"UCaaaaaaaaaaaaaaaaaaaaaa"}}},
      {"snippet":{"title":"Chan B","description":"desc b","publishedAt":"2026-02-01T00:00:00Z","resourceId":{"channelId":"UCbbbbbbbbbbbbbbbbbbbbbb"}}}
    ],"nextPageToken":"next-page"}
    """#

    private static let uploadsByPlaylist = [
        "UUaaaaaaaaaaaaaaaaaaaaaa": #"""
        {"items":[
          {"contentDetails":{"videoId":"vidAAAAAAA1"},"snippet":{"title":"A recent","description":"ra","channelId":"UCaaaaaaaaaaaaaaaaaaaaaa","channelTitle":"Chan A","publishedAt":"2026-09-17T00:00:00Z"}},
          {"contentDetails":{"videoId":"vidAAAAAAA2"},"snippet":{"title":"A old","description":"oa","channelId":"UCaaaaaaaaaaaaaaaaaaaaaa","channelTitle":"Chan A","publishedAt":"2026-08-01T00:00:00Z"}}
        ]}
        """#,
        "UUbbbbbbbbbbbbbbbbbbbbbb": #"""
        {"items":[
          {"snippet":{"title":"B newest","description":"nb","channelId":"UCbbbbbbbbbbbbbbbbbbbbbb","channelTitle":"Chan B","publishedAt":"2026-09-18T09:00:00Z","resourceId":{"videoId":"vidBBBBBBB1"}}}
        ]}
        """#,
    ]

    private func transport(subscriptions: String? = YouTubeSubscriptionReadTests.subscriptions, uploads: [String: String] = YouTubeSubscriptionReadTests.uploadsByPlaylist) -> YouTubeFixtureTransport {
        YouTubeFixtureTransport { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.path {
            case "/youtube/v3/subscriptions": return subscriptions
            case "/youtube/v3/playlistItems": return uploads[query.first { $0.name == "playlistId" }?.value ?? ""]
            default: return nil
            }
        }
    }

    private func reader(_ transport: YouTubeFixtureTransport) -> DirectAccountReader {
        DirectAccountReader(transport: transport, bearer: { _ in "token" }, now: { Self.now })
    }

    private func rows(_ page: AccountReadPage) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)) as? [[String: Any]])
    }

    func testSubscriptionsListsTheChannelsWithTheirIDLiftedToTheTopLevel() async throws {
        let transport = self.transport()
        let page = try await self.reader(transport).read(.init(operation: .youtubeSubscriptions, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let rows = try self.rows(page)
        let sent = await transport.urls
        let request = try XCTUnwrap(sent.first)
        let query = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(request.host, "www.googleapis.com")
        XCTAssertEqual(request.path, "/youtube/v3/subscriptions")
        XCTAssertEqual(query.first { $0.name == "mine" }?.value, "true")
        XCTAssertEqual(query.first { $0.name == "part" }?.value, "snippet")
        XCTAssertEqual(query.first { $0.name == "maxResults" }?.value, "5")
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.nextCursor, "next-page")
        XCTAssertEqual(Set(rows[0].keys), ["channelId", "title", "description", "subscribedAt"])
        XCTAssertEqual(rows[0]["channelId"] as? String, "UCaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(rows[0]["title"] as? String, "Chan A")
        XCTAssertEqual(rows[0]["subscribedAt"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(rows[1]["channelId"] as? String, "UCbbbbbbbbbbbbbbbbbbbbbb")
    }

    func testFeedMergesEveryChannelsUploadsNewestFirstAndDropsAnythingOlderThanAWeek() async throws {
        let transport = self.transport()
        let page = try await self.reader(transport).read(.init(operation: .youtubeSubscriptionFeed, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let rows = try self.rows(page)
        let paths = await transport.urls.map(\.path)
        let playlists = await transport.urls.filter { $0.path == "/youtube/v3/playlistItems" }
            .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "playlistId" }?.value }
        XCTAssertEqual(paths.filter { $0 == "/youtube/v3/subscriptions" }.count, 1)
        XCTAssertEqual(Set(playlists), ["UUaaaaaaaaaaaaaaaaaaaaaa", "UUbbbbbbbbbbbbbbbbbbbbbb"])
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.count, 2, "the August upload is outside the seven-day window")
        XCTAssertEqual(rows[0]["videoId"] as? String, "vidBBBBBBB1")
        XCTAssertEqual(rows[1]["videoId"] as? String, "vidAAAAAAA1")
        XCTAssertEqual(rows[0]["url"] as? String, "https://www.youtube.com/watch?v=vidBBBBBBB1")
        XCTAssertEqual(rows[0]["channelTitle"] as? String, "Chan B")
        XCTAssertEqual(rows[0]["channelId"] as? String, "UCbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertEqual(Set(rows[0].keys), ["videoId", "title", "channelId", "channelTitle", "publishedAt", "description", "url"])
    }

    func testFeedReturnsAtMostTheRequestedNumberOfVideos() async throws {
        let page = try await self.reader(self.transport()).read(.init(operation: .youtubeSubscriptionFeed, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 1, cursor: nil))
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(try self.rows(page)[0]["videoId"] as? String, "vidBBBBBBB1")
    }

    func testFeedForOneChannelSkipsTheSubscriptionList() async throws {
        let transport = self.transport()
        let page = try await self.reader(transport).read(.init(operation: .youtubeSubscriptionFeed, query: nil, channel: "UCbbbbbbbbbbbbbbbbbbbbbb", timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let paths = await transport.urls.map(\.path)
        XCTAssertEqual(paths, ["/youtube/v3/playlistItems"])
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(try self.rows(page)[0]["videoId"] as? String, "vidBBBBBBB1")
    }

    func testFeedStillAnswersWhenOneChannelsUploadsCannotBeRead() async throws {
        let transport = self.transport(uploads: ["UUaaaaaaaaaaaaaaaaaaaaaa": Self.uploadsByPlaylist["UUaaaaaaaaaaaaaaaaaaaaaa"]!])
        let page = try await self.reader(transport).read(.init(operation: .youtubeSubscriptionFeed, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let rows = try self.rows(page)
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(rows[0]["videoId"] as? String, "vidAAAAAAA1")
    }
}

/// Answers by URL; nil means a 404 with an empty body.
private actor YouTubeFixtureTransport: PhoneHTTPTransport {
    private let answer: @Sendable (URL) -> String?
    private(set) var urls: [URL] = []
    init(_ answer: @escaping @Sendable (URL) -> String?) { self.answer = answer }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        self.urls.append(url)
        guard let body = self.answer(url) else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
