import Foundation
import XCTest
@testable import OperatorApp

/// "Can you read my unread Slack messages" got "Slack doesn't expose
/// read/unread status". It does: conversations.info carries the channel's
/// last_read and unread_count for the signed-in person. These pin that
/// both Slack reads carry it, plus sender names for the user ids.
final class SlackReadMetadataTests: XCTestCase {
    private static let channels = #"{"ok":true,"channels":[{"id":"C1","name":"social","is_private":false,"is_archived":false,"is_member":true,"num_members":4,"created":1700000000,"topic":{"value":"chat"},"purpose":{"value":""}},{"id":"C2","name":"issues","is_private":true,"is_member":true,"num_members":2}],"response_metadata":{"next_cursor":"next-1"}}"#
    private static let infoByChannel = [
        "C1": #"{"ok":true,"channel":{"id":"C1","last_read":"1700000010.000100","unread_count":2,"unread_count_display":1}}"#,
        "C2": #"{"ok":true,"channel":{"id":"C2","last_read":"1700000099.000000","unread_count":0,"unread_count_display":0}}"#,
    ]
    private static let history = #"{"ok":true,"messages":[{"type":"message","ts":"1700000020.000200","user":"U1","text":"newest","reply_count":2,"reactions":[{"name":"eyes","count":1}]},{"type":"message","ts":"1700000010.000100","user":"U2","text":"seen already","subtype":"thread_broadcast"},{"type":"message","ts":"1700000001.000000","bot_id":"B9","text":"from a bot"}],"response_metadata":{"next_cursor":""}}"#
    private static let usersByID = [
        "U1": #"{"ok":true,"user":{"id":"U1","name":"sam","real_name":"Sam Lee","profile":{"display_name":"sam"}}}"#,
        "U2": #"{"ok":true,"user":{"id":"U2","name":"ana","real_name":"Ana Ruiz","profile":{"display_name":""}}}"#,
    ]

    private func transport() -> SlackFixtureTransport {
        SlackFixtureTransport { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.path {
            case "/api/conversations.list": return Self.channels
            case "/api/conversations.info": return Self.infoByChannel[query.first { $0.name == "channel" }?.value ?? ""]
            case "/api/conversations.history": return Self.history
            case "/api/users.info": return Self.usersByID[query.first { $0.name == "user" }?.value ?? ""]
            default: return nil
            }
        }
    }

    private func rows(_ page: AccountReadPage) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)) as? [[String: Any]])
    }

    func testChannelListCarriesEachChannelsUnreadCountAndMembership() async throws {
        let transport = self.transport()
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let page = try await reader.read(.init(operation: .slackChannels, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let rows = try self.rows(page)
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.nextCursor, "next-1")
        XCTAssertEqual(rows[0]["name"] as? String, "social")
        XCTAssertEqual(rows[0]["unread_count"] as? Int, 2)
        XCTAssertEqual(rows[0]["unread_count_display"] as? Int, 1)
        XCTAssertEqual(rows[0]["last_read"] as? String, "1700000010.000100")
        XCTAssertEqual(rows[0]["num_members"] as? Int, 4)
        XCTAssertEqual(rows[0]["is_member"] as? Bool, true)
        XCTAssertEqual(rows[0]["created"] as? Int, 1700000000)
        XCTAssertEqual(rows[1]["unread_count"] as? Int, 0)
        let paths = await transport.paths
        XCTAssertEqual(paths.filter { $0 == "/api/conversations.info" }.count, 2)
    }

    func testHistoryMarksEachMessageUnreadAgainstLastReadAndNamesTheSender() async throws {
        let transport = self.transport()
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let page = try await reader.read(.init(operation: .slackHistory, query: nil, channel: "C1", timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let rows = try self.rows(page)
        XCTAssertEqual(page.count, 3)
        XCTAssertNil(page.nextCursor)
        // Newer than last_read 1700000010.000100 -> unread; equal or older -> read.
        XCTAssertEqual(rows[0]["unread"] as? Bool, true)
        XCTAssertEqual(rows[1]["unread"] as? Bool, false)
        XCTAssertEqual(rows[2]["unread"] as? Bool, false)
        XCTAssertEqual(rows[0]["user_name"] as? String, "Sam Lee")
        XCTAssertEqual(rows[1]["user_name"] as? String, "Ana Ruiz")
        XCTAssertNil(rows[2]["user_name"])
        XCTAssertEqual(rows[2]["bot_id"] as? String, "B9")
        XCTAssertEqual(rows[0]["reply_count"] as? Int, 2)
        XCTAssertNotNil(rows[0]["reactions"])
        XCTAssertEqual(rows[1]["subtype"] as? String, "thread_broadcast")
        // Channel-level state rides on every row so the model sees it whatever it reads.
        XCTAssertEqual(rows[0]["channel_unread_count"] as? Int, 2)
        XCTAssertEqual(rows[0]["channel_last_read"] as? String, "1700000010.000100")
        let paths = await transport.paths
        XCTAssertEqual(paths.filter { $0 == "/api/users.info" }.count, 2, "each sender looked up once")
        XCTAssertEqual(paths.filter { $0 == "/api/conversations.info" }.count, 1)
    }

    func testHistoryStillAnswersWhenTheExtraLookupsFail() async throws {
        let transport = SlackFixtureTransport { url in
            url.path == "/api/conversations.history" ? Self.history : #"{"ok":false,"error":"missing_scope"}"#
        }
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let page = try await reader.read(.init(operation: .slackHistory, query: nil, channel: "C1", timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let rows = try self.rows(page)
        XCTAssertEqual(page.count, 3)
        XCTAssertNil(rows[0]["unread"])
        XCTAssertNil(rows[0]["user_name"])
        XCTAssertEqual(rows[0]["text"] as? String, "newest")
    }
}

/// Answers by path; nil means a 404 with an empty body.
private actor SlackFixtureTransport: PhoneHTTPTransport {
    private let answer: @Sendable (URL) -> String?
    private(set) var paths: [String] = []
    init(_ answer: @escaping @Sendable (URL) -> String?) { self.answer = answer }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        self.paths.append(url.path)
        guard let body = self.answer(url) else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
