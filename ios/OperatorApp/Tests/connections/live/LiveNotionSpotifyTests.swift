import Foundation
import XCTest
@testable import OperatorApp

// Live-account proofs for Notion (MCP) and Spotify — the two connectors the
// earlier live suite did not fully cover. Like LiveConnectorTests these use the
// REAL tokens the app stored in the Keychain and cost nothing (no LLM turn);
// only the connector HTTPS calls run. Gated on OPERATOR_LIVE=1 (OperatorAppLive
// scheme). Notion writes create a private draft page and archive it afterwards.
// Spotify start-playback is audible on the owner's active device — the owner
// has authorised that, and the test only plays when a device is already active.

private func liveOn() -> Bool { ProcessInfo.processInfo.environment["OPERATOR_LIVE"] == "1" }

@MainActor private final class NoopPresenter: OAuthSessionPresenting {
    func authenticate(url: URL, callbackScheme: String?) async throws -> URL { throw CancellationError() }
    func cancel() {}
}

// Compact JSON string for a NotionJSONValue (it is Codable), truncated for logs.
private func jsonString(_ value: NotionJSONValue, limit: Int = 4000) -> String {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    guard let data = try? enc.encode(value) else { return "<unencodable>" }
    let s = String(decoding: data, as: UTF8.self)
    return s.count > limit ? String(s.prefix(limit)) + "…(+\(s.count - limit))" : s
}

private extension NotionJSONValue {
    var asObject: [String: NotionJSONValue]? { if case let .object(o) = self { return o } else { return nil } }
    var asArray: [NotionJSONValue]? { if case let .array(a) = self { return a } else { return nil } }
    var asString: String? { if case let .string(s) = self { return s } else { return nil } }
}

// First Notion page id (dashed UUID, or bare 32-hex) found in a result string.
private func firstNotionID(in text: String) -> String? {
    let dashed = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    if let r = text.range(of: dashed, options: .regularExpression) { return String(text[r]) }
    if let r = text.range(of: "[0-9a-f]{32}", options: .regularExpression) { return String(text[r]) }
    return nil
}

@MainActor
final class LiveNotionTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(liveOn(), "live-account test; run via the OperatorAppLive scheme (OPERATOR_LIVE=1)")
    }

    private func connectedClient() async throws -> NotionMCPClient {
        let coordinator = NativeNotionSetupCoordinator(bundle: .main, presenter: NoopPresenter())
        let client = coordinator.client
        do { try await client.restore() }
        catch { throw XCTSkip("Notion not connected on this device: \(error)") }
        _ = try await client.initialize()
        return client
    }

    // READ + discovery: list the tool catalog and run a real search so we see the
    // result shape and prove the app can read the owner's live workspace.
    func testNotionListToolsAndSearch() async throws {
        let client = try await connectedClient()

        let tools: NotionJSONValue = try await client.listTools()
        let toolList = tools.asObject?["tools"]?.asArray ?? []
        let names = toolList.compactMap { $0.asObject?["name"]?.asString }
        print("LIVE-NOTION tools count=\(names.count) names=\(names.joined(separator: ","))")
        XCTAssertGreaterThan(names.count, 0, "Notion MCP should expose at least one tool")

        guard let searchName = names.first(where: { $0.lowercased().contains("search") }) else {
            throw XCTSkip("no search-like Notion tool found; names=\(names)")
        }
        let result = try await client.callTool(name: searchName, arguments: ["query": .string("a")])
        print("LIVE-NOTION read tool=\(searchName) result=\(jsonString(result, limit: 3000))")
        XCTAssertNotNil(result.asObject, "search result should be a JSON object")
    }

    // The Operator Notion connector can create/read/update pages but has NO
    // delete/archive path (no MCP tool exposes it, and the MCP OAuth token is
    // rejected 401 by api.notion.com REST). So the write proof is REVERSIBLE and
    // leaves nothing behind: it appends a uniquely-marked line to a single reused
    // fixture page, fetches to prove the write landed, then removes the line and
    // fetches again to prove the page is back to its prior state.
    private let knownFixtureID = "3dae6004-5e9f-8131-a66b-ec4c2919ebcb"

    func testNotionAppendVerifyRemove() async throws {
        let client = try await connectedClient()
        let fixtureID = try await fixturePageID(client)
        let mark = "opwrite-\(UUID().uuidString.prefix(8).lowercased())"
        let markerLine = "OPERATOR-LIVE-WRITE \(mark)"

        // WRITE — append the marked line to the fixture page.
        _ = try await client.callTool(name: "notion-update-page", arguments: [
            "page_id": .string(fixtureID),
            "command": .string("insert_content"),
            "content": .string(markerLine),
            "position": .object(["type": .string("end")]),
            "allow_async": .bool(false),
        ])

        // VERIFY — fetch and confirm the mark is present.
        let afterInsert = jsonString(try await client.callTool(name: "notion-fetch",
                                                               arguments: ["id": .string(fixtureID)]), limit: 8000)
        let inserted = afterInsert.contains(mark)
        print("LIVE-NOTION-WRITE fixture=\(fixtureID) inserted=\(inserted)")

        // CLEANUP (reversible) — remove the marked line via search-and-replace.
        _ = try await client.callTool(name: "notion-update-page", arguments: [
            "page_id": .string(fixtureID),
            "command": .string("update_content"),
            "content_updates": .array([.object(["old_str": .string(markerLine), "new_str": .string("")])]),
            "allow_async": .bool(false),
        ])

        // VERIFY cleanup — fetch and confirm the mark is gone.
        let afterRemove = jsonString(try await client.callTool(name: "notion-fetch",
                                                               arguments: ["id": .string(fixtureID)]), limit: 8000)
        let removed = !afterRemove.contains(mark)
        print("LIVE-NOTION-WRITE inserted=\(inserted) removed=\(removed)")

        XCTAssertTrue(inserted, "the appended marker should be present after the write")
        XCTAssertTrue(removed, "the appended marker should be gone after the reversible cleanup")
    }

    // Returns the reusable fixture page id, recreating it (as a private draft) if it
    // no longer exists so the test self-heals.
    private func fixturePageID(_ client: NotionMCPClient) async throws -> String {
        if let existing = try? await client.callTool(name: "notion-fetch", arguments: ["id": .string(knownFixtureID)]),
           jsonString(existing, limit: 400).contains("\"type\":\"page\"") || jsonString(existing, limit: 400).contains("<page") {
            return knownFixtureID
        }
        let created = try await client.callTool(name: "notion-create-pages", arguments: [
            "creation_mode": .string("draft"),
            "allow_async": .bool(false),
            "pages": .array([.object([
                "properties": .object(["title": .string("Operator Live Test Fixture — safe to delete")]),
                "content": .string("Reusable fixture for the Operator iOS Notion connector live write test."),
            ])]),
        ])
        guard let id = firstNotionID(in: jsonString(created, limit: 8000)) else {
            throw XCTSkip("could not find or create the Notion fixture page")
        }
        print("LIVE-NOTION-WRITE created new fixture=\(id) (update knownFixtureID)")
        return id
    }
}

@MainActor
final class LiveSpotifyPlaybackTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(liveOn(), "live-account test; run via the OperatorAppLive scheme (OPERATOR_LIVE=1)")
    }

    private func coordinator() -> NativeAccountSetupCoordinator {
        NativeAccountSetupCoordinator(bundle: .main, presenter: NoopPresenter())
    }
    private func reader(_ c: NativeAccountSetupCoordinator) -> DirectAccountReader {
        DirectAccountReader(bearer: { p in try await c.accessToken(p) })
    }
    private func writer(_ c: NativeAccountSetupCoordinator) -> DirectAccountWriter {
        DirectAccountWriter(bearer: { p in try await c.accessToken(p) })
    }

    // FREE: detect whether Spotify has an active device right now (GET /me/player)
    // and resolve a real track URI from search — the two things playback needs.
    // The search sanitizer keeps `id` (the 22-char track id) but not `uri`, so we
    // build the URI as spotify:track:<id>. No playback is started here.
    func testSpotifyDetectDeviceAndResolveTrack() async throws {
        let c = coordinator()
        do { _ = try await c.accessToken(.spotify) }
        catch { throw XCTSkip("Spotify not connected on this device") }

        let state = try await reader(c).read(.init(operation: .spotifyPlayback, query: nil, channel: nil,
                                                   timeMin: nil, timeMax: nil, limit: 1, cursor: nil))
        print("LIVE-SPOTIFY playbackState count=\(state.count) payload=\(state.payloadJSON.prefix(600))")

        let search = try await reader(c).read(.init(operation: .spotifySearch, query: "lofi beats", channel: nil,
                                                    timeMin: nil, timeMax: nil, limit: 3, cursor: nil))
        print("LIVE-SPOTIFY searchPayload=\(search.payloadJSON.prefix(600))")
        let uri = firstTrackURI(in: search.payloadJSON)
        print("LIVE-SPOTIFY resolvedTrackURI=\(uri ?? "<none>") activeDevice=\(activeDeviceID(in: state.payloadJSON) ?? "<none>")")
        XCTAssertNotNil(uri, "search should resolve at least one spotify:track: URI")
    }

    // Playback: only runs when a Spotify device is already active (owner opened
    // Spotify somewhere). Resolves a track and starts it on that device through the
    // app's write path, then asserts the .spotifyPlaybackStarted receipt.
    func testSpotifyStartPlaybackOnActiveDevice() async throws {
        let c = coordinator()
        do { _ = try await c.accessToken(.spotify) }
        catch { throw XCTSkip("Spotify not connected on this device") }

        let state = try await reader(c).read(.init(operation: .spotifyPlayback, query: nil, channel: nil,
                                                   timeMin: nil, timeMax: nil, limit: 1, cursor: nil))
        guard state.count > 0 else {
            throw XCTSkip("no active Spotify device — open Spotify on a device and press play/pause (Premium required), then rerun")
        }
        let deviceID = activeDeviceID(in: state.payloadJSON)

        let search = try await reader(c).read(.init(operation: .spotifySearch, query: "lofi beats", channel: nil,
                                                    timeMin: nil, timeMax: nil, limit: 3, cursor: nil))
        guard let trackURI = firstTrackURI(in: search.payloadJSON) else {
            return XCTFail("could not resolve a track URI to play")
        }

        let receipt = try await writer(c).writeAfterOwnerConfirmation(
            .spotifyStartPlayback(.init(trackURI: trackURI, deviceID: deviceID)))
        print("LIVE-SPOTIFY-PLAY trackURI=\(trackURI) device=\(deviceID ?? "<active>") receipt=\(receipt)")
        XCTAssertEqual(receipt, .spotifyPlaybackStarted, "playback should start and return the started receipt")
    }

    // A track's URI is spotify:track:<id>; the search payload carries `id`.
    private func firstTrackURI(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for track in array {
            if let id = track["id"] as? String,
               id.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil {
                return "spotify:track:\(id)"
            }
        }
        return nil
    }

    // The active device id from a GET /me/player payload ({device:{id,...},...}).
    private func activeDeviceID(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let device = first["device"] as? [String: Any] else { return nil }
        return device["id"] as? String
    }
}
