import Foundation
import XCTest
@testable import OperatorApp

final class DirectAccountWriterTests: XCTestCase {
    func testGoogleCalendarCreateEventUsesFixedEndpointAndSanitizesReceipt() async throws {
        let transport = WriteFixtureTransport(status: 200, body: #"{"id":"event-1","summary":"Standup","creator":{"email":"private@example.com"}}"#)
        let writer = DirectAccountWriter(transport: transport, bearer: { provider in
            XCTAssertEqual(provider, .google)
            return "access-secret"
        })

        let receipt = try await writer.writeAfterOwnerConfirmation(.googleCalendarCreateEvent(.init(
            summary: "Standup",
            description: "Daily sync",
            startRFC3339: "2026-09-09T14:00:00Z",
            endRFC3339: "2026-09-09T14:30:00Z"
        )))

        XCTAssertEqual(receipt, .googleCalendarEvent(id: "event-1"))
        let capturedRequest = await transport.onlyRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://www.googleapis.com/calendar/v3/calendars/primary/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try jsonObject(request.httpBody)
        XCTAssertEqual(body["summary"] as? String, "Standup")
        XCTAssertEqual(body["description"] as? String, "Daily sync")
        XCTAssertEqual((body["start"] as? [String: String])?["dateTime"], "2026-09-09T14:00:00Z")
        XCTAssertEqual((body["end"] as? [String: String])?["dateTime"], "2026-09-09T14:30:00Z")
        XCTAssertEqual(Set(body.keys), ["summary", "description", "start", "end"])
    }

    func testGoogleCalendarCreateEventWithGuestsSendsInvitations() async throws {
        let transport = WriteFixtureTransport(status: 200, body: #"{"id":"event-2"}"#)
        let writer = DirectAccountWriter(transport: transport, bearer: { _ in "token" })

        let receipt = try await writer.writeAfterOwnerConfirmation(.googleCalendarCreateEvent(.init(
            summary: "Planning", description: "", startRFC3339: "2026-09-09T14:00:00Z", endRFC3339: "2026-09-09T14:30:00Z",
            attendees: ["ann@example.com", "bob@example.com"])))

        XCTAssertEqual(receipt, .googleCalendarEvent(id: "event-2"))
        let captured = await transport.onlyRequest()
        let request = try XCTUnwrap(captured)
        // sendUpdates=all is what makes Google email the guests; without it the
        // event silently lists them.
        XCTAssertEqual(request.url?.absoluteString, "https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=all")
        let body = try jsonObject(request.httpBody)
        XCTAssertEqual(body["attendees"] as? [[String: String]], [["email": "ann@example.com"], ["email": "bob@example.com"]])
        XCTAssertEqual(Set(body.keys), ["summary", "description", "start", "end", "attendees"])
    }

    func testGoogleCalendarUpdateEventPatchesOnlyTheGivenFields() async throws {
        let transport = WriteFixtureTransport(status: 200, body: #"{"id":"event-3","summary":"Moved","attendees":[{"email":"private@example.com"}]}"#)
        let writer = DirectAccountWriter(transport: transport, bearer: { provider in
            XCTAssertEqual(provider, .google)
            return "access-secret"
        })

        let receipt = try await writer.writeAfterOwnerConfirmation(.googleCalendarUpdateEvent(.init(
            eventID: "abc123_20260909T140000Z", summary: "Moved", description: nil,
            startRFC3339: "2026-09-09T15:00:00Z", endRFC3339: "2026-09-09T15:30:00Z", attendees: nil)))

        XCTAssertEqual(receipt, .googleCalendarEvent(id: "event-3"))
        let captured = await transport.onlyRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://www.googleapis.com/calendar/v3/calendars/primary/events/abc123_20260909T140000Z?sendUpdates=all")
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-secret")
        let body = try jsonObject(request.httpBody)
        XCTAssertEqual(Set(body.keys), ["summary", "start", "end"], "absent fields are not sent, so Google leaves them alone")
        XCTAssertEqual(body["summary"] as? String, "Moved")
        XCTAssertEqual((body["start"] as? [String: String])?["dateTime"], "2026-09-09T15:00:00Z")

        let guests = WriteFixtureTransport(status: 200, body: #"{"id":"event-3"}"#)
        let guestWriter = DirectAccountWriter(transport: guests, bearer: { _ in "token" })
        _ = try await guestWriter.writeAfterOwnerConfirmation(.googleCalendarUpdateEvent(.init(
            eventID: "event-3", summary: nil, description: "Room 4", startRFC3339: nil, endRFC3339: nil, attendees: ["ann@example.com"])))
        let guestRequest = await guests.onlyRequest()
        let guestBody = try jsonObject(try XCTUnwrap(guestRequest).httpBody)
        XCTAssertEqual(Set(guestBody.keys), ["description", "attendees"])
        XCTAssertEqual(guestBody["attendees"] as? [[String: String]], [["email": "ann@example.com"]])
    }

    func testGoogleDriveCreateTextFileUsesOneBoundedMultipartRelatedRequest() async throws {
        let transport = WriteFixtureTransport(status: 200, body: #"{"id":"file-1","name":"notes.txt","mimeType":"text/plain","owners":[{"emailAddress":"private@example.com"}]}"#)
        let writer = DirectAccountWriter(transport: transport, bearer: { _ in "token" })

        let receipt = try await writer.writeAfterOwnerConfirmation(.googleDriveCreateTextFile(.init(name: "notes.txt", content: "hello drive")))

        XCTAssertEqual(receipt, .googleDriveFile(id: "file-1"))
        let capturedRequest = await transport.onlyRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")
        XCTAssertEqual(request.httpMethod, "POST")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/related; boundary="))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#""mimeType":"text\/plain""#))
        XCTAssertTrue(body.contains(#""name":"notes.txt""#))
        XCTAssertTrue(body.contains("Content-Type: text/plain; charset=UTF-8\r\n\r\nhello drive"))
        let driveCallCount = await transport.callCount()
        XCTAssertEqual(driveCallCount, 1)
    }

    func testOutlookDraftAndSendUseOnlyDocumentedFixedEndpoints() async throws {
        let draftTransport = WriteFixtureTransport(status: 201, body: #"{"id":"draft-1","subject":"Follow up","body":{"content":"private"}}"#)
        let draftWriter = DirectAccountWriter(transport: draftTransport, bearer: { provider in
            XCTAssertEqual(provider, .microsoftOutlook)
            return "token"
        })
        let draft = try await draftWriter.writeAfterOwnerConfirmation(.outlookCreateDraft(.init(subject: "Follow up", body: "Draft body")))
        XCTAssertEqual(draft, .outlookDraft(id: "draft-1"))
        let capturedDraftRequest = await draftTransport.onlyRequest()
        let draftRequest = try XCTUnwrap(capturedDraftRequest)
        XCTAssertEqual(draftRequest.url?.absoluteString, "https://graph.microsoft.com/v1.0/me/messages")
        let draftBody = try jsonObject(draftRequest.httpBody)
        XCTAssertEqual((draftBody["body"] as? [String: String])?["contentType"], "Text")
        XCTAssertNil(draftBody["toRecipients"])

        let sendTransport = WriteFixtureTransport(status: 202, body: "")
        let sendWriter = DirectAccountWriter(transport: sendTransport, bearer: { _ in "token" })
        let sent = try await sendWriter.writeAfterOwnerConfirmation(.outlookSendMail(.init(to: "person@example.com", subject: "Hello", body: "Message body")))
        XCTAssertEqual(sent, .outlookMailAccepted)
        let capturedSendRequest = await sendTransport.onlyRequest()
        let sendRequest = try XCTUnwrap(capturedSendRequest)
        XCTAssertEqual(sendRequest.url?.absoluteString, "https://graph.microsoft.com/v1.0/me/sendMail")
        let sendBody = try jsonObject(sendRequest.httpBody)
        XCTAssertEqual(sendBody["saveToSentItems"] as? Bool, true)
        let message = try XCTUnwrap(sendBody["message"] as? [String: Any])
        let recipients = try XCTUnwrap(message["toRecipients"] as? [[String: Any]])
        XCTAssertEqual(((recipients.first?["emailAddress"] as? [String: String])?["address"]), "person@example.com")
    }

    func testSlackPostAndSpotifyPlaybackUseFixedOperationShapes() async throws {
        let slackTransport = WriteFixtureTransport(status: 200, body: #"{"ok":true,"channel":"C123","ts":"1720000000.000100","message":{"text":"private copy"}}"#)
        let slackWriter = DirectAccountWriter(transport: slackTransport, bearer: { provider in
            XCTAssertEqual(provider, .slack)
            return "token"
        })
        let posted = try await slackWriter.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello")))
        XCTAssertEqual(posted, .slackMessage(channelID: "C123", timestamp: "1720000000.000100"))
        let capturedSlackRequest = await slackTransport.onlyRequest()
        let slackRequest = try XCTUnwrap(capturedSlackRequest)
        XCTAssertEqual(slackRequest.url?.absoluteString, "https://slack.com/api/chat.postMessage")
        XCTAssertEqual(try jsonObject(slackRequest.httpBody)["text"] as? String, "hello")

        let spotifyTransport = WriteFixtureTransport(status: 204, body: "")
        let spotifyWriter = DirectAccountWriter(transport: spotifyTransport, bearer: { provider in
            XCTAssertEqual(provider, .spotify)
            return "token"
        })
        let played = try await spotifyWriter.writeAfterOwnerConfirmation(.spotifyStartPlayback(.init(
            trackURI: "spotify:track:4uLU6hMCjMI75M1A2tKUQC",
            deviceID: "0d1841b0976bae2a3a310dd74c0f3df354899bc8"
        )))
        XCTAssertEqual(played, .spotifyPlaybackStarted)
        let capturedSpotifyRequest = await spotifyTransport.onlyRequest()
        let spotifyRequest = try XCTUnwrap(capturedSpotifyRequest)
        XCTAssertEqual(spotifyRequest.url?.host, "api.spotify.com")
        XCTAssertEqual(spotifyRequest.url?.path, "/v1/me/player/play")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(spotifyRequest.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "0d1841b0976bae2a3a310dd74c0f3df354899bc8")
        XCTAssertEqual(spotifyRequest.httpMethod, "PUT")
        XCTAssertEqual(try jsonObject(spotifyRequest.httpBody)["uris"] as? [String], ["spotify:track:4uLU6hMCjMI75M1A2tKUQC"])
    }

    func testEveryInvalidDTOFailsBeforeBearerOrTransport() async {
        let transport = WriteFixtureTransport(status: 200, body: "{}")
        let tokens = WriteTokenCalls()
        let writer = DirectAccountWriter(transport: transport, bearer: { _ in
            await tokens.record()
            return "token"
        })
        let invalid: [AccountWriteRequest] = [
            .googleCalendarCreateEvent(.init(summary: " ", description: "", startRFC3339: "2026-09-09T14:00:00Z", endRFC3339: "2026-09-09T14:30:00Z")),
            .googleCalendarCreateEvent(.init(summary: "Event", description: "", startRFC3339: "2026-09-09T15:00:00Z", endRFC3339: "2026-09-09T14:30:00Z")),
            .googleCalendarCreateEvent(.init(summary: "Event", description: "", startRFC3339: "2026-09-09T14:00:00Z", endRFC3339: "2026-09-09T14:30:00Z", attendees: ["not-an-email"])),
            .googleCalendarCreateEvent(.init(summary: "Event", description: "", startRFC3339: "2026-09-09T14:00:00Z", endRFC3339: "2026-09-09T14:30:00Z", attendees: ["a@example.com", "A@example.com"])),
            .googleCalendarCreateEvent(.init(summary: "Event", description: "", startRFC3339: "2026-09-09T14:00:00Z", endRFC3339: "2026-09-09T14:30:00Z", attendees: (0..<51).map { "guest\($0)@example.com" })),
            // Nothing to change; a bad id; a start without an end; end before start; an empty summary.
            .googleCalendarUpdateEvent(.init(eventID: "event-1", summary: nil, description: nil, startRFC3339: nil, endRFC3339: nil, attendees: nil)),
            .googleCalendarUpdateEvent(.init(eventID: "../calendars/other", summary: "x", description: nil, startRFC3339: nil, endRFC3339: nil, attendees: nil)),
            .googleCalendarUpdateEvent(.init(eventID: "event-1", summary: nil, description: nil, startRFC3339: "2026-09-09T14:00:00Z", endRFC3339: nil, attendees: nil)),
            .googleCalendarUpdateEvent(.init(eventID: "event-1", summary: nil, description: nil, startRFC3339: "2026-09-09T15:00:00Z", endRFC3339: "2026-09-09T14:00:00Z", attendees: nil)),
            .googleCalendarUpdateEvent(.init(eventID: "event-1", summary: " ", description: nil, startRFC3339: nil, endRFC3339: nil, attendees: nil)),
            .googleDriveCreateTextFile(.init(name: "bad\nname.txt", content: "body")),
            .outlookCreateDraft(.init(subject: "", body: "body")),
            .outlookSendMail(.init(to: "not-an-email", subject: "subject", body: "body")),
            .outlookSendMail(.init(to: "a@example.com", subject: "subject", body: " ")),
            .slackPostMessage(.init(channelID: "https://evil.invalid", text: "hello")),
            .slackPostMessage(.init(channelID: "C123", text: String(repeating: "x", count: 4_001))),
            .spotifyStartPlayback(.init(trackURI: "https://evil.invalid/track", deviceID: nil)),
            .spotifyStartPlayback(.init(trackURI: "spotify:track:4uLU6hMCjMI75M1A2tKUQC", deviceID: "bad device")),
        ]

        for request in invalid {
            await XCTAssertThrowsWriteError(try await writer.writeAfterOwnerConfirmation(request), equals: .invalidRequest)
        }
        let tokenCount = await tokens.count()
        let invalidRequestCallCount = await transport.callCount()
        XCTAssertEqual(tokenCount, 0)
        XCTAssertEqual(invalidRequestCallCount, 0)
    }

    func testTransportFailureAfterSingleAttemptIsUnknownAndNeverSafeToRetry() async {
        let transport = WriteFixtureTransport(error: URLError(.networkConnectionLost))
        let writer = DirectAccountWriter(transport: transport, bearer: { _ in "token" })

        await XCTAssertThrowsWriteError(
            try await writer.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello"))),
            equals: .outcomeUnknownNotSafeToRetry(operation: .slackPostMessage)
        )
        let failureCallCount = await transport.callCount()
        XCTAssertEqual(failureCallCount, 1)
    }

    func testCancellationIsPreservedBeforeDispatchButUnknownAfterDispatch() async {
        let before = DirectAccountWriter(transport: WriteFixtureTransport(status: 200, body: "{}"), bearer: { _ in throw CancellationError() })
        await XCTAssertThrowsCancellation(try await before.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello"))))

        let bearerURLCancellation = DirectAccountWriter(transport: WriteFixtureTransport(status: 200, body: "{}"), bearer: { _ in throw URLError(.cancelled) })
        do {
            _ = try await bearerURLCancellation.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello")))
            XCTFail("Expected URL cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Expected URLError.cancelled, got \(type(of: error))")
        }

        let during = DirectAccountWriter(transport: WriteFixtureTransport(error: CancellationError()), bearer: { _ in "token" })
        await XCTAssertThrowsWriteError(
            try await during.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello"))),
            equals: .outcomeUnknownNotSafeToRetry(operation: .slackPostMessage)
        )

        let duringURLCancellation = DirectAccountWriter(transport: WriteFixtureTransport(error: URLError(.cancelled)), bearer: { _ in "token" })
        await XCTAssertThrowsWriteError(
            try await duringURLCancellation.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello"))),
            equals: .outcomeUnknownNotSafeToRetry(operation: .slackPostMessage)
        )
    }

    func testKnownFailuresReturnOnlyBoundedErrorCodes() async {
        let denied = DirectAccountWriter(transport: WriteFixtureTransport(status: 403, body: #"{"error":"secret remote detail"}"#), bearer: { _ in "token" })
        await XCTAssertThrowsWriteError(try await denied.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello"))), equals: .permissionDenied)

        let limited = DirectAccountWriter(transport: WriteFixtureTransport(status: 429, body: "{}", headers: ["Retry-After": "999999"]), bearer: { _ in "token" })
        await XCTAssertThrowsWriteError(try await limited.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello"))), equals: .rateLimited(retryAfterSeconds: 86_400))

    }

    func testSuccessfulWriteWithInvalidOrOversizedReceiptIsUnknownNotSafeToRetry() async {
        let malformed = DirectAccountWriter(transport: WriteFixtureTransport(status: 200, body: #"{"ok":true,"channel":"C123","ts":"not a timestamp","private":"must not escape"}"#), bearer: { _ in "token" })
        await XCTAssertThrowsWriteError(
            try await malformed.writeAfterOwnerConfirmation(.slackPostMessage(.init(channelID: "C123", text: "hello"))),
            equals: .outcomeUnknownNotSafeToRetry(operation: .slackPostMessage)
        )

        let oversized = DirectAccountWriter(transport: WriteFixtureTransport(status: 200, body: String(repeating: "x", count: 65_537)), bearer: { _ in "token" })
        await XCTAssertThrowsWriteError(
            try await oversized.writeAfterOwnerConfirmation(.googleDriveCreateTextFile(.init(name: "notes.txt", content: "hello"))),
            equals: .outcomeUnknownNotSafeToRetry(operation: .googleDriveCreateTextFile)
        )
    }
}

private actor WriteFixtureTransport: PhoneHTTPTransport {
    private let status: Int
    private let body: String
    private let headers: [String: String]
    private let error: Error?
    private var requests: [URLRequest] = []

    init(status: Int = 200, body: String, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
        self.error = nil
    }

    init(error: Error) {
        self.status = 0
        self.body = ""
        self.headers = [:]
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        if let error = self.error { throw error }
        return (
            Data(self.body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: self.headers)!
        )
    }

    func onlyRequest() -> URLRequest? { self.requests.count == 1 ? self.requests[0] : nil }
    func callCount() -> Int { self.requests.count }
}

private actor WriteTokenCalls {
    private var value = 0
    func record() { self.value += 1 }
    func count() -> Int { self.value }
}

private func jsonObject(_ data: Data?) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
}

private func XCTAssertThrowsWriteError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: AccountWriteError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected AccountWriteError", file: file, line: line)
    } catch let error as AccountWriteError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
    }
}

private func XCTAssertThrowsCancellation<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
        return
    } catch {
        XCTFail("Expected CancellationError, got \(type(of: error))", file: file, line: line)
    }
}
