import Foundation
import XCTest
@testable import OperatorApp

final class DirectAccountReaderTests: XCTestCase {
    func testGoogleCalendarBuildsBoundedReadOnlyRequestAfterValidation() async throws {
        let transport = ReadFixtureTransport(body: #"{"items":[],"nextPageToken":"cursor-2"}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let page = try await reader.read(.init(operation: .googleCalendarEvents, query: "standup", channel: nil, timeMin: "2026-09-09T00:00:00Z", timeMax: "2026-09-10T00:00:00Z", limit: 5, cursor: nil))
        let captured = await transport.request
        let request = try XCTUnwrap(captured)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(query?.value(for: "q"), "standup")
        XCTAssertEqual(query?.value(for: "maxResults"), "5")
        XCTAssertEqual(page.nextCursor, "cursor-2")
    }

    func testInvalidInputAndForeignCursorNeverRequestBearer() async {
        let transport = ReadFixtureTransport(body: "{}")
        let calls = TokenCalls()
        let reader = DirectAccountReader(transport: transport, bearer: { _ in await calls.called(); return "token" })
        await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .spotifySearch, query: "", channel: nil, timeMin: nil, timeMax: nil, limit: 4, cursor: nil)))
        await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .googleDriveFiles, query: "x", channel: nil, timeMin: nil, timeMax: nil, limit: 4, cursor: "https://evil.invalid")))
        let callCount = await calls.value
        let request = await transport.request
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(request)
    }

    func testSlackFalseOKAndHttpStatusesAreSanitized() async throws {
        let slack = DirectAccountReader(transport: ReadFixtureTransport(body: #"{"ok":false,"error":"not_authed"}"#), bearer: { _ in "token" })
        await XCTAssertThrowsErrorAsync(try await slack.read(.init(operation: .slackChannels, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 2, cursor: nil))) { error in
            XCTAssertEqual(error as? AccountReadError, .unavailable)
        }
        let unauthorized = DirectAccountReader(transport: ReadFixtureTransport(status: 401, body: "{}"), bearer: { _ in "token" })
        await XCTAssertThrowsErrorAsync(try await unauthorized.read(.init(operation: .spotifyPlayback, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 1, cursor: nil))) { error in
            XCTAssertEqual(error as? AccountReadError, .notConnected)
        }
    }

    func testCalendarWindowIsRFC3339AndOrderedAndSpotifyEmptyPlaybackIsValid() async throws {
        let reader = DirectAccountReader(transport: ReadFixtureTransport(status: 204, body: ""), bearer: { _ in "token" })
        let empty = try await reader.read(.init(operation: .spotifyPlayback, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 1, cursor: nil))
        XCTAssertEqual(empty.count, 0)
        let calendar = DirectAccountReader(transport: ReadFixtureTransport(body: #"{"items":[]}"#), bearer: { _ in "token" })
        await XCTAssertThrowsErrorAsync(try await calendar.read(.init(operation: .googleCalendarEvents, query: nil, channel: nil, timeMin: "2026-09-10", timeMax: "2026-09-09", limit: 1, cursor: nil)))
    }

    // --- Drive / Spotify tolerant free-text query -------------------------
    // A user's request is natural language, not a prescribed format. The reader
    // must accept spaces and punctuation; only a query that is empty once
    // trimmed (i.e. no query at all) is refused. These prove the whole path
    // from request to built URL, so a future strict-format regression is caught.

    func testGoogleDriveAcceptsAMultiWordQueryWithSpaces() async throws {
        let transport = ReadFixtureTransport(body: #"{"files":[]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        _ = try await reader.read(.init(operation: .googleDriveFiles, query: "budget report q1", channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        let captured = await transport.request
        let request = try XCTUnwrap(captured)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        // Spaces survive untouched into the Drive query-language clause.
        XCTAssertEqual(items?.value(for: "q"), "name contains 'budget report q1' and trashed = false")
    }

    func testGoogleDriveEscapesApostropheAndBackslashRatherThanRejecting() async throws {
        let transport = ReadFixtureTransport(body: #"{"files":[]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        _ = try await reader.read(.init(operation: .googleDriveFiles, query: #"o'brien\notes"#, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        let captured = await transport.request
        let request = try XCTUnwrap(captured)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        // Drive metacharacters are escaped (\\ and \'), not grounds for refusal.
        XCTAssertEqual(items?.value(for: "q"), #"name contains 'o\'brien\\notes' and trashed = false"#)
    }

    func testSpotifySearchRoundTripsAMultiWordQueryLosslessly() async throws {
        let transport = ReadFixtureTransport(body: #"{"tracks":{"items":[]}}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        _ = try await reader.read(.init(operation: .spotifySearch, query: "bohemian rhapsody queen", channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        let captured = await transport.request
        let request = try XCTUnwrap(captured)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        // Percent-encoding on the wire decodes back to the exact words typed.
        XCTAssertEqual(items?.value(for: "q"), "bohemian rhapsody queen")
    }

    func testDriveAndSpotifyRefuseAWhitespaceOnlyQueryWithoutCallingOut() async {
        for operation in [AccountReadOperation.googleDriveFiles, .spotifySearch] {
            let transport = ReadFixtureTransport(body: "{}")
            let calls = TokenCalls()
            let reader = DirectAccountReader(transport: transport, bearer: { _ in await calls.called(); return "token" })

            await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: operation, query: "   ", channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))) { error in
                XCTAssertEqual(error as? AccountReadError, .invalidRequest, "operation=\(operation)")
            }
            let callCount = await calls.value
            let request = await transport.request
            XCTAssertEqual(callCount, 0, "operation=\(operation): a refused request must never mint a token")
            XCTAssertNil(request, "operation=\(operation): a refused request must never reach the network")
        }
    }

    // --- outlookCalendarEvents -------------------------------------------

    func testOutlookCalendarUsesCalendarViewSoRecurringSeriesAreExpanded() async throws {
        let transport = ReadFixtureTransport(body: #"{"value":[]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        _ = try await reader.read(.init(operation: .outlookCalendarEvents, query: nil, channel: nil, timeMin: "2026-09-01T00:00:00Z", timeMax: "2026-09-08T00:00:00Z", limit: 5, cursor: nil))

        let captured = await transport.request
        let request = try XCTUnwrap(captured)
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(components?.host, "graph.microsoft.com")
        // calendarView, not /events. Graph expands a recurring series only
        // here; against /events a weekly standup appears once, on the day it
        // was created. This is the Graph equivalent of Google's singleEvents.
        XCTAssertEqual(components?.path, "/v1.0/me/calendarView")
        XCTAssertEqual(components?.queryItems?.value(for: "startDateTime"), "2026-09-01T00:00:00Z")
        XCTAssertEqual(components?.queryItems?.value(for: "endDateTime"), "2026-09-08T00:00:00Z")
        XCTAssertEqual(components?.queryItems?.value(for: "$top"), "5")
        XCTAssertEqual(components?.queryItems?.value(for: "$orderby"), "start/dateTime")
    }

    func testOutlookCalendarReturnsOnlyAllowlistedKeys() async throws {
        let body = #"""
        {"value":[{"id":"AAA","subject":"Standup","start":{"dateTime":"2026-09-02T09:00:00"},"end":{"dateTime":"2026-09-02T09:15:00"},"isAllDay":false,"location":{"displayName":"Room 1"},"webLink":"https://outlook.office.com/x","organizer":{"emailAddress":{"name":"A"}},"bodyPreview":"private agenda","attendees":[{"emailAddress":{"address":"b@example.com"}}]}]}
        """#
        let reader = DirectAccountReader(transport: ReadFixtureTransport(body: body), bearer: { _ in "token" })

        let page = try await reader.read(.init(operation: .outlookCalendarEvents, query: nil, channel: nil, timeMin: "2026-09-01T00:00:00Z", timeMax: "2026-09-08T00:00:00Z", limit: 5, cursor: nil))

        XCTAssertEqual(page.count, 1)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "subject", "start", "end", "location", "isAllDay", "webLink", "organizer"])
        // Both were in the response and neither reaches the agent. The
        // allowlist decides what may be seen, not what Graph chose to send.
        XCTAssertNil(rows[0]["bodyPreview"])
        XCTAssertNil(rows[0]["attendees"])
    }

    func testOutlookCalendarRefusesAMissingOrInvertedWindowWithoutCallingOut() async {
        let windows: [(String?, String?)] = [
            (nil, "2026-09-08T00:00:00Z"),
            ("2026-09-01T00:00:00Z", nil),
            ("2026-09-08T00:00:00Z", "2026-09-01T00:00:00Z"),
            ("not-a-date", "2026-09-08T00:00:00Z"),
        ]
        for (timeMin, timeMax) in windows {
            let transport = ReadFixtureTransport(body: "{}")
            let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

            await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .outlookCalendarEvents, query: nil, channel: nil, timeMin: timeMin, timeMax: timeMax, limit: 5, cursor: nil))) { error in
                XCTAssertEqual(error as? AccountReadError, .invalidRequest, "window=\(String(describing: timeMin))..\(String(describing: timeMax))")
            }
            let request = await transport.request
            XCTAssertNil(request, "a refused request must never reach the network")
        }
    }

    // A nextLink is a URL the server chose. Following one unchecked is how a
    // paging cursor becomes a redirect, so only the exact host, the exact
    // path and a non-negative $skip survive.
    func testOutlookCalendarAcceptsOnlyItsOwnNextLinkAsACursor() async throws {
        let good = DirectAccountReader(
            transport: ReadFixtureTransport(body: #"{"value":[],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendarView?$skip=5"}"#),
            bearer: { _ in "token" })
        let page = try await good.read(.init(operation: .outlookCalendarEvents, query: nil, channel: nil, timeMin: "2026-09-01T00:00:00Z", timeMax: "2026-09-08T00:00:00Z", limit: 5, cursor: nil))
        XCTAssertEqual(page.nextCursor, "5")

        for link in [
            "https://evil.example.com/v1.0/me/calendarView?$skip=5",
            "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$skip=5",
            "https://graph.microsoft.com/v1.0/me/calendarView?$skip=-1",
            "https://graph.microsoft.com/v1.0/me/calendarView",
        ] {
            let reader = DirectAccountReader(
                transport: ReadFixtureTransport(body: "{\"value\":[],\"@odata.nextLink\":\"\(link)\"}"),
                bearer: { _ in "token" })
            await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .outlookCalendarEvents, query: nil, channel: nil, timeMin: "2026-09-01T00:00:00Z", timeMax: "2026-09-08T00:00:00Z", limit: 5, cursor: nil))) { error in
                XCTAssertEqual(error as? AccountReadError, .invalidResponse, "link=\(link)")
            }
        }
    }

    func testOutlookCalendarRefusesMoreRowsThanWereAskedFor() async {
        let rows = (0 ..< 6).map { "{\"id\":\"\($0)\",\"subject\":\"s\"}" }.joined(separator: ",")
        let reader = DirectAccountReader(
            transport: ReadFixtureTransport(body: "{\"value\":[\(rows)]}"),
            bearer: { _ in "token" })

        await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .outlookCalendarEvents, query: nil, channel: nil, timeMin: "2026-09-01T00:00:00Z", timeMax: "2026-09-08T00:00:00Z", limit: 5, cursor: nil))) { error in
            XCTAssertEqual(error as? AccountReadError, .invalidResponse)
        }
    }

    func testCalendarsReadRidesTheMicrosoftClientThatAlreadySignsIn() {
        XCTAssertEqual(AccountReadOperation.outlookCalendarEvents.provider, .microsoftOutlook)
        XCTAssertTrue(OAuthProvider.microsoftOutlook.scopes.contains("Calendars.Read"))
        XCTAssertTrue(OAuthProvider.microsoftOutlook.requiredAccessTokenScopes.contains("Calendars.Read"))
        // Sign-in metadata is not an API permission and must stay out of the
        // access-token check, or a valid token reads as an incomplete one.
        XCTAssertFalse(OAuthProvider.microsoftOutlook.requiredAccessTokenScopes.contains("openid"))
        XCTAssertFalse(OAuthProvider.microsoftOutlook.requiredAccessTokenScopes.contains("offline_access"))
    }
    // --- gmailMessages ----------------------------------------------------

    func testGmailListsThenFetchesMetadataForEachID() async throws {
        let transport = GmailFixtureTransport(listBody: Self.threeGmailIDs)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        let page = try await reader.read(.init(operation: .gmailMessages, query: "is:unread", channel: nil, timeMin: nil, timeMax: nil, limit: 3, cursor: "page-1"))

        // Everything is read off the actor first: XCTAssert takes autoclosures,
        // and an actor-isolated property cannot be reached from inside one.
        let listCalls = await transport.listCalls
        let metadataCalls = await transport.metadataCalls
        let urls = await transport.urls

        // One list call plus one metadata call per id. users.messages.list
        // returns nothing but ids and there is no list endpoint carrying a
        // subject or a sender, so this shape is Gmail's, not a choice.
        XCTAssertEqual(listCalls, 1)
        XCTAssertEqual(metadataCalls, 3)
        XCTAssertEqual(page.count, 3)
        XCTAssertEqual(page.nextCursor, "page-2")

        let list = try XCTUnwrap(urls.first { $0.path == "/gmail/v1/users/me/messages" })
        let listQuery = URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(listQuery?.value(for: "maxResults"), "3")
        XCTAssertEqual(listQuery?.value(for: "q"), "is:unread")
        XCTAssertEqual(listQuery?.value(for: "pageToken"), "page-1")

        let metadata = try XCTUnwrap(urls.first { $0.path.hasPrefix("/gmail/v1/users/me/messages/") })
        let items = try XCTUnwrap(URLComponents(url: metadata, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.value(for: "format"), "metadata")
        XCTAssertEqual(Set(items.filter { $0.name == "metadataHeaders" }.compactMap(\.value)), ["Subject", "From", "Date"])
    }

    // The stub answers metadata calls out of order on purpose. Gmail returns
    // newest first and that ordering is most of the value of the read; a task
    // group does not preserve it.
    func testGmailPreservesListOrderDespiteConcurrentReplies() async throws {
        for _ in 0 ..< 8 {
            let transport = GmailFixtureTransport(listBody: Self.threeGmailIDs)
            let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

            let page = try await reader.read(.init(operation: .gmailMessages, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 3, cursor: nil))

            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)) as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["m1", "m2", "m3"])
        }
    }

    func testGmailBuildsRowsFieldByFieldRatherThanCopyingTheResponse() async throws {
        let transport = GmailFixtureTransport(listBody: #"{"messages":[{"id":"m1"}]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        let page = try await reader.read(.init(operation: .gmailMessages, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 1, cursor: nil))

        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "threadId", "snippet", "subject", "from", "date"])
        // The fixture spells it "subject"; Gmail spells it "Subject".
        XCTAssertEqual(rows[0]["subject"] as? String, "Subject m1")
        XCTAssertEqual(rows[0]["from"] as? String, "a@example.com")
        // All present in the response and none of them reach the agent.
        XCTAssertNil(rows[0]["labelIds"])
        XCTAssertNil(rows[0]["internalDate"])
        XCTAssertNil(rows[0]["payload"])
        XCTAssertNil(rows[0]["bcc"])
    }

    func testGmailTreatsAnAbsentMessagesKeyAsAnEmptyResult() async throws {
        let transport = GmailFixtureTransport(listBody: #"{"resultSizeEstimate":0}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        let page = try await reader.read(.init(operation: .gmailMessages, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        // Gmail omits "messages" entirely when nothing matches. That is an
        // empty inbox view, not a malformed response.
        XCTAssertEqual(page.count, 0)
        XCTAssertEqual(page.payloadJSON, "[]")
        XCTAssertNil(page.nextCursor)
        let metadataCalls = await transport.metadataCalls
        XCTAssertEqual(metadataCalls, 0)
    }

    func testGmailRefusesMoreIDsThanWereAskedFor() async {
        let transport = GmailFixtureTransport(listBody: #"{"messages":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .gmailMessages, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 2, cursor: nil))) { error in
            XCTAssertEqual(error as? AccountReadError, .invalidResponse)
        }
    }

    func testGmailRefusesRequestShapesItCannotServe() async {
        let shapes: [(String, AccountReadRequest)] = [
            ("limit above the Gmail cap", .init(operation: .gmailMessages, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 11, cursor: nil)),
            ("limit of zero", .init(operation: .gmailMessages, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 0, cursor: nil)),
            ("blank query", .init(operation: .gmailMessages, query: "   ", channel: nil, timeMin: nil, timeMax: nil, limit: 3, cursor: nil)),
            ("a channel", .init(operation: .gmailMessages, query: nil, channel: "C1", timeMin: nil, timeMax: nil, limit: 3, cursor: nil)),
            ("a time window", .init(operation: .gmailMessages, query: nil, channel: nil, timeMin: "2026-09-01T00:00:00Z", timeMax: nil, limit: 3, cursor: nil)),
        ]
        for (label, request) in shapes {
            let transport = GmailFixtureTransport(listBody: Self.threeGmailIDs)
            let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

            await XCTAssertThrowsErrorAsync(try await reader.read(request)) { error in
                XCTAssertEqual(error as? AccountReadError, .invalidRequest, label)
            }
            let seen = await transport.urls
            XCTAssertTrue(seen.isEmpty, "\(label): a refused request must never reach the network")
        }
    }

    // A partial page is worse than no page: it silently omits mail. One bad
    // metadata call has to fail the whole read.
    func testGmailFailsTheWholeReadWhenOneMetadataCallFails() async {
        let transport = GmailFixtureTransport(listBody: Self.threeGmailIDs, messageStatus: 403)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .gmailMessages, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 3, cursor: nil))) { error in
            XCTAssertEqual(error as? AccountReadError, .permissionDenied)
        }
    }

    func testGmailRidesTheGoogleClient() {
        XCTAssertEqual(AccountReadOperation.gmailMessages.provider, .google)
        XCTAssertTrue(OAuthProvider.google.scopes.contains("https://www.googleapis.com/auth/gmail.readonly"))
        // Read-only, and nothing else. If a send or modify scope ever
        // appears here it should be because someone argued for it.
        XCTAssertFalse(OAuthProvider.google.scopes.contains { $0.contains("gmail") && !$0.hasSuffix("gmail.readonly") })
        // Lower than the shared limit on purpose: each row costs a request.
        XCTAssertEqual(DirectAccountReader.gmailMaximumLimit, 10)
    }

    private static let threeGmailIDs = #"{"messages":[{"id":"m1"},{"id":"m2"},{"id":"m3"}],"nextPageToken":"page-2"}"#

    // --- googleTasks ------------------------------------------------------

    func testGoogleTasksDefaultsToTheDefaultListAndHidesCompletedWork() async throws {
        let transport = ReadFixtureTransport(body: #"{"items":[{"id":"1","title":"Ship it","status":"needsAction","notes":"n","due":"2026-09-11T00:00:00Z","hidden":false,"etag":"x"}],"nextPageToken":"p2"}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        let page = try await reader.read(.init(operation: .googleTasks, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        let captured = await transport.request
        let request = try XCTUnwrap(captured)
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.host, "tasks.googleapis.com")
        XCTAssertEqual(components?.path, "/tasks/v1/lists/@default/tasks")
        XCTAssertEqual(components?.queryItems?.value(for: "showCompleted"), "false")
        XCTAssertEqual(components?.queryItems?.value(for: "maxResults"), "5")
        XCTAssertEqual(page.nextCursor, "p2")

        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "title", "notes", "due", "status"])
        XCTAssertNil(rows[0]["etag"])
    }

    // A task list id is placed in the URL path, not the query. Anything that
    // could leave its own segment changes which endpoint is called, so it is
    // checked before a request exists rather than escaped on the way out.
    func testGoogleTasksRefusesAListIdThatCouldLeaveItsPathSegment() async {
        _ = try? await DirectAccountReader(transport: ReadFixtureTransport(body: #"{"items":[]}"#), bearer: { _ in "token" })
            .read(.init(operation: .googleTasks, query: nil, channel: "MTIzNDU2", timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        for channel in ["../../v1/spaces", "a/b", "a?b=c", "a#b", "", String(repeating: "x", count: 129)] {
            let transport = ReadFixtureTransport(body: "{}")
            let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

            await XCTAssertThrowsErrorAsync(try await reader.read(.init(operation: .googleTasks, query: nil, channel: channel, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))) { error in
                XCTAssertEqual(error as? AccountReadError, .invalidRequest, "channel=\(channel)")
            }
            let seen = await transport.request
            XCTAssertNil(seen, "channel=\(channel): a refused request must never reach the network")
        }
    }

    func testGoogleTasksUsesANamedListWhenGivenOne() async throws {
        let transport = ReadFixtureTransport(body: #"{"items":[]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })

        _ = try await reader.read(.init(operation: .googleTasks, query: nil, channel: "MTIzNDU2", timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        // Read off the actor first: XCTUnwrap takes an autoclosure, and an
        // actor-isolated property cannot be reached from inside one.
        let captured = await transport.request
        let request = try XCTUnwrap(captured)
        let path = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.path

        XCTAssertEqual(path, "/tasks/v1/lists/MTIzNDU2/tasks")
    }

    // Tasks omits items entirely when the list is empty. That is an empty
    // result, not a broken one.
    func testAbsentItemsReadAsAnEmptyResult() async throws {
        let reader = DirectAccountReader(transport: ReadFixtureTransport(body: "{}"), bearer: { _ in "token" })

        let page = try await reader.read(.init(operation: .googleTasks, query: nil, channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))

        XCTAssertEqual(page.count, 0)
        XCTAssertEqual(page.payloadJSON, "[]")
    }

    func testGoogleTasksScopeIsReadOnlyAndOnTheExistingClient() {
        let scopes = OAuthProvider.google.scopes
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/tasks.readonly"))
        XCTAssertFalse(scopes.contains { $0.contains("tasks") && !$0.hasSuffix(".readonly") })
        XCTAssertEqual(OAuthProvider.allCases.count, 4, "no new OAuth client was introduced")
        XCTAssertEqual(AccountReadOperation.googleTasks.provider, .google)
    }

    // Dropped deliberately rather than forgotten. Google Contacts duplicated
    // the phone's own address book, which costs no OAuth and no review, and
    // Google Chat is a Workspace product with thin consumer use - two scopes
    // reaching message content for the narrowest audience on the list. If
    // either is ever reinstated it should be an argument, not a reflex.
    func testDroppedGoogleScopesStayDropped() {
        for scope in ["contacts.readonly", "chat.spaces.readonly", "chat.messages.readonly"] {
            XCTAssertFalse(OAuthProvider.google.scopes.contains("https://www.googleapis.com/auth/\(scope)"), scope)
        }
        XCTAssertFalse(OAuthProvider.google.scopes.contains { $0.contains("/chat.") || $0.contains("/contacts") })
    }
}

private actor GmailFixtureTransport: PhoneHTTPTransport {
    private(set) var urls: [URL] = []
    private let listBody: String
    private let messageStatus: Int

    init(listBody: String, messageStatus: Int = 200) {
        self.listBody = listBody
        self.messageStatus = messageStatus
    }

    var listCalls: Int { self.urls.filter { $0.path == "/gmail/v1/users/me/messages" }.count }
    var metadataCalls: Int { self.urls.filter { $0.path.hasPrefix("/gmail/v1/users/me/messages/") }.count }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        self.urls.append(url)
        if url.path == "/gmail/v1/users/me/messages" {
            return (Data(self.listBody.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let id = url.lastPathComponent
        // Answered out of order relative to the list, on purpose.
        try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000 ... 200_000))
        let body = """
        {"id":"\(id)","threadId":"T\(id)","snippet":"preview of \(id)",
         "payload":{"headers":[{"name":"From","value":"a@example.com"},
                               {"name":"subject","value":"Subject \(id)"},
                               {"name":"Date","value":"Tue, 2 Sep 2026 09:00:00 +0000"},
                               {"name":"Bcc","value":"private@example.com"}]},
         "internalDate":"1756800000000","labelIds":["INBOX"]}
        """
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: self.messageStatus, httpVersion: nil, headerFields: nil)!)
    }
}

private actor TokenCalls { private var count = 0; func called() { self.count += 1 }; var value: Int { self.count } }
private actor ReadFixtureTransport: PhoneHTTPTransport {
    let status: Int; let body: String; var request: URLRequest?
    init(status: Int = 200, body: String) { self.status = status; self.body = body }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
    }
}
private extension Array where Element == URLQueryItem { func value(for name: String) -> String? { first { $0.name == name }?.value } }
private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ handler: @escaping (Error) -> Void = { _ in }) async { do { _ = try await expression(); XCTFail("Expected error") } catch { handler(error) } }
