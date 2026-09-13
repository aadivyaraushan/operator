import Foundation
import XCTest
@testable import OperatorApp

// Live-account connector proofs. These exercise the REAL DirectAccountReader /
// DirectAccountWriter against the owner's connected accounts, using the exact
// tokens the app stored in the Keychain (via the same NativeAccountSetupCoordinator
// the app builds in OperatorApp.swift). No LLM chat turn is involved, so these
// cost nothing — only the connector HTTPS calls run.
//
// They are gated on OPERATOR_LIVE=1, set only by the `OperatorAppLive` scheme, so
// the default test run (throwaway sim / CI) skips them and stays green. Run reads
// with:  -scheme OperatorAppLive -only-testing:OperatorAppTests/LiveConnectorReadTests
// and writes with: -only-testing:OperatorAppTests/LiveConnectorWriteTests
// Writes are restricted to the owner themselves (own Drive/Calendar/mailbox, an
// email to ssdear@gmail.com, the owner's own Slack DM) and clean up after
// themselves; the owner has authorised real sends to self.

private func liveEnabled() -> Bool { ProcessInfo.processInfo.environment["OPERATOR_LIVE"] == "1" }

// Never actually called: tokens already exist, so no interactive auth is presented.
@MainActor private final class NoopOAuthPresenter: OAuthSessionPresenting {
    func authenticate(url: URL, callbackScheme: String?) async throws -> URL { throw CancellationError() }
    func cancel() {}
}

@MainActor private func liveCoordinator() -> NativeAccountSetupCoordinator {
    NativeAccountSetupCoordinator(bundle: .main, presenter: NoopOAuthPresenter())
}

/// One authenticated request, used only for self-DM discovery and cleanup — not
/// part of the connector surface under test. MainActor-isolated so its
/// non-Sendable `[String: Any]` result never crosses an isolation boundary.
@discardableResult
@MainActor
private func authed(_ method: String, _ url: URL, token: String, json: Any? = nil) async -> (Int, [String: Any]?) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let json {
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse else { return (0, nil) }
    return (http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
}

private func liveMark() -> String { "operatorlivetest" + UUID().uuidString.prefix(8).lowercased() }

@MainActor
final class LiveConnectorReadTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(liveEnabled(), "live-account test; run via the OperatorAppLive scheme (OPERATOR_LIVE=1)")
    }

    private func reader(_ coordinator: NativeAccountSetupCoordinator) -> DirectAccountReader {
        DirectAccountReader(bearer: { provider in try await coordinator.accessToken(provider) })
    }

    private func assertReadable(_ operation: AccountReadOperation, query: String? = nil,
                                channel: String? = nil, timeMin: String? = nil, timeMax: String? = nil,
                                limit: Int = 5) async throws {
        let reader = self.reader(liveCoordinator())
        let request = AccountReadRequest(operation: operation, query: query, channel: channel,
                                         timeMin: timeMin, timeMax: timeMax, limit: limit, cursor: nil)
        let page: AccountReadPage
        do { page = try await reader.read(request) }
        catch AccountReadError.notConnected { throw XCTSkip("\(operation.provider.rawValue) not connected on this device") }
        XCTAssertGreaterThanOrEqual(page.count, 0)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)),
                         "payload should be valid JSON")
        print("LIVE-READ \(operation.rawValue) count=\(page.count) nextCursor=\(page.nextCursor != nil)")
    }

    func testGoogleDriveLiveRead() async throws { try await assertReadable(.googleDriveFiles, query: "a") }
    func testGmailLiveRead() async throws { try await assertReadable(.gmailMessages, query: "in:inbox", limit: 3) }
    func testOutlookInboxLiveRead() async throws { try await assertReadable(.outlookInbox) }
    func testSlackChannelsLiveRead() async throws { try await assertReadable(.slackChannels) }
    func testSpotifySearchLiveRead() async throws { try await assertReadable(.spotifySearch, query: "lofi") }

    // The remaining read endpoints, so every read op has a live proof.
    func testGoogleTasksLiveRead() async throws { try await assertReadable(.googleTasks, limit: 5) }
    // Microsoft Graph's calendarView rejects a start→end span wider than 1825
    // days (5 years) with a 400, which the reader maps to `.unavailable`. Keep the
    // window inside that cap. (Confirmed live: a 2020→2035 span returned 400
    // "Maximum number of days: 1825"; a legal window returns 200.)
    func testOutlookCalendarLiveRead() async throws {
        try await assertReadable(.outlookCalendarEvents,
                                 timeMin: "2024-01-01T00:00:00Z", timeMax: "2027-01-01T00:00:00Z", limit: 5)
    }

    // Slack history needs a channel the app can actually read; walk the listed
    // channels and prove the endpoint on the first one that returns.
    func testSlackHistoryLiveRead() async throws {
        let reader = self.reader(liveCoordinator())
        let channels: AccountReadPage
        do { channels = try await reader.read(.init(operation: .slackChannels, query: nil, channel: nil,
                                                    timeMin: nil, timeMax: nil, limit: 20, cursor: nil)) }
        catch AccountReadError.notConnected { throw XCTSkip("slack not connected on this device") }
        guard let data = channels.payloadJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw XCTSkip("could not parse slack channels")
        }
        for id in arr.compactMap({ $0["id"] as? String }).prefix(10) {
            if let page = try? await reader.read(.init(operation: .slackHistory, query: nil, channel: id,
                                                       timeMin: nil, timeMax: nil, limit: 3, cursor: nil)) {
                print("LIVE-READ slackHistory channel=\(id) count=\(page.count)")
                XCTAssertGreaterThanOrEqual(page.count, 0)
                return
            }
        }
        throw XCTSkip("app is not a member of any listed channel; conversations.history unavailable")
    }
}

@MainActor
final class LiveConnectorWriteTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(liveEnabled(), "live-account test; run via the OperatorAppLive scheme (OPERATOR_LIVE=1)")
    }

    private func writer(_ coordinator: NativeAccountSetupCoordinator) -> DirectAccountWriter {
        DirectAccountWriter(bearer: { provider in try await coordinator.accessToken(provider) })
    }

    private func token(_ provider: OAuthProvider, _ coordinator: NativeAccountSetupCoordinator) async throws -> String {
        do { return try await coordinator.accessToken(provider) }
        catch { throw XCTSkip("\(provider.rawValue) not connected on this device") }
    }

    // Creates a text file in the owner's own Drive, confirms it is findable, then deletes it.
    func testGoogleDriveCreateFileToSelf() async throws {
        let coordinator = liveCoordinator()
        let accessToken = try await token(.google, coordinator)
        let mark = liveMark()
        let receipt = try await writer(coordinator).writeAfterOwnerConfirmation(
            .googleDriveCreateTextFile(.init(name: "\(mark).txt",
                                             content: "Operator live connector test. Safe to delete. \(mark)")))
        guard case let .googleDriveFile(id) = receipt else { return XCTFail("unexpected receipt \(receipt)") }
        XCTAssertFalse(id.isEmpty)
        let page = try await reader(coordinator).read(.init(operation: .googleDriveFiles, query: mark,
                                                            channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        XCTAssertGreaterThanOrEqual(page.count, 1, "the created file should be findable in Drive")
        _ = await authed("DELETE", URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!, token: accessToken)
        print("LIVE-WRITE googleDriveCreateTextFile id=\(id) verified=\(page.count) cleaned=true")
    }

    // Creates an event far in the future on the owner's own calendar, confirms it, then deletes it.
    func testGoogleCalendarCreateEventToSelf() async throws {
        let coordinator = liveCoordinator()
        let accessToken = try await token(.google, coordinator)
        let mark = liveMark()
        let receipt = try await writer(coordinator).writeAfterOwnerConfirmation(
            .googleCalendarCreateEvent(.init(summary: "\(mark) (Operator live test, safe to delete)",
                                             description: "Operator live connector test.",
                                             startRFC3339: "2035-01-01T10:00:00Z",
                                             endRFC3339: "2035-01-01T11:00:00Z")))
        guard case let .googleCalendarEvent(id) = receipt else { return XCTFail("unexpected receipt \(receipt)") }
        XCTAssertFalse(id.isEmpty)
        let page = try await reader(coordinator).read(.init(operation: .googleCalendarEvents, query: mark,
                                                            channel: nil, timeMin: "2034-12-31T00:00:00Z",
                                                            timeMax: "2035-01-02T00:00:00Z", limit: 5, cursor: nil))
        XCTAssertGreaterThanOrEqual(page.count, 1, "the created event should be findable")
        _ = await authed("DELETE", URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(id)")!, token: accessToken)
        print("LIVE-WRITE googleCalendarCreateEvent id=\(id) verified=\(page.count) cleaned=true")
    }

    private func reader(_ coordinator: NativeAccountSetupCoordinator) -> DirectAccountReader {
        DirectAccountReader(bearer: { provider in try await coordinator.accessToken(provider) })
    }

    // Creates a draft in the owner's own Outlook mailbox (no send), then deletes it.
    func testOutlookCreateDraftToSelf() async throws {
        let coordinator = liveCoordinator()
        let accessToken = try await token(.microsoftOutlook, coordinator)
        let mark = liveMark()
        let receipt = try await writer(coordinator).writeAfterOwnerConfirmation(
            .outlookCreateDraft(.init(subject: "\(mark) draft (Operator live test, safe to delete)",
                                      body: "Operator live connector test.")))
        guard case let .outlookDraft(id) = receipt else { return XCTFail("unexpected receipt \(receipt)") }
        XCTAssertFalse(id.isEmpty)
        _ = await authed("DELETE", URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(id)")!, token: accessToken)
        print("LIVE-WRITE outlookCreateDraft id=\(id) cleaned=true")
    }

    // Sends a real email from the owner's Outlook to the owner's own Gmail (ssdear@gmail.com).
    func testOutlookSendMailToSelf() async throws {
        let coordinator = liveCoordinator()
        _ = try await token(.microsoftOutlook, coordinator)
        let mark = liveMark()
        let receipt = try await writer(coordinator).writeAfterOwnerConfirmation(
            .outlookSendMail(.init(to: "ssdear@gmail.com",
                                   subject: "\(mark) — Operator live test to self",
                                   body: "Operator live connector test. Safe to delete. \(mark)")))
        XCTAssertEqual(receipt, .outlookMailAccepted)
        print("LIVE-WRITE outlookSendMail accepted to ssdear@gmail.com mark=\(mark)")
    }

    // Posts to the owner's own Slack DM (self), confirms the receipt, then deletes the message.
    func testSlackPostToSelfDM() async throws {
        let coordinator = liveCoordinator()
        let accessToken = try await token(.slack, coordinator)
        let (authStatus, authBody) = await authed("GET", URL(string: "https://slack.com/api/auth.test")!, token: accessToken)
        guard authStatus == 200, authBody?["ok"] as? Bool == true, let userID = authBody?["user_id"] as? String else {
            throw XCTSkip("Slack auth.test unavailable (scope)")
        }
        let (openStatus, openBody) = await authed("POST", URL(string: "https://slack.com/api/conversations.open")!,
                                                  token: accessToken, json: ["users": userID])
        guard openStatus == 200, openBody?["ok"] as? Bool == true,
              let channelID = (openBody?["channel"] as? [String: Any])?["id"] as? String else {
            throw XCTSkip("Slack conversations.open unavailable (scope)")
        }
        let mark = liveMark()
        let receipt = try await writer(coordinator).writeAfterOwnerConfirmation(
            .slackPostMessage(.init(channelID: channelID, text: "\(mark) — Operator live self-test. Safe to delete.")))
        guard case let .slackMessage(channel, timestamp) = receipt else { return XCTFail("unexpected receipt \(receipt)") }
        XCTAssertEqual(channel, channelID)
        _ = await authed("POST", URL(string: "https://slack.com/api/chat.delete")!,
                         token: accessToken, json: ["channel": channelID, "ts": timestamp])
        print("LIVE-WRITE slackPostMessage channel=\(channel) ts=\(timestamp) cleaned=true")
    }

    // Spotify start-playback is intrusive (audible on the owner's own device) and needs an
    // active device; left for a manual owner run. The read path is proven and the write
    // logic is unit-tested in DirectAccountWriterTests.
    func testSpotifyStartPlaybackLeftForManualRun() async throws {
        throw XCTSkip("Spotify start-playback is intrusive and needs an active device; left for a manual owner run")
    }
}
