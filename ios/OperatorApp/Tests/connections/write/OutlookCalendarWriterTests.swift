import Foundation
import XCTest
@testable import OperatorApp

/// The owner asked for "founders interview prep at 8pm on my Outlook calendar"
/// and was told it was unsupported. These cover adding an event and changing one.
final class OutlookCalendarWriterTests: XCTestCase {
    private func send(_ input: AccountWriteRequest, status: Int, body: String) async throws -> (AccountWriteReceipt, URLRequest) {
        let transport = OutlookFixtureTransport(status: status, body: body)
        let writer = DirectAccountWriter(transport: transport, bearer: { provider in
            XCTAssertEqual(provider, .microsoftOutlook)
            return "token"
        })
        let receipt = try await writer.writeAfterOwnerConfirmation(input)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        return (receipt, try XCTUnwrap(requests.first))
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testMicrosoftScopeAllowsChangingTheCalendar() {
        let scopes = OAuthProvider.microsoftOutlook.scopes
        XCTAssertTrue(scopes.contains("Calendars.ReadWrite"))
        XCTAssertFalse(scopes.contains("Calendars.Read"))
    }

    func testAnEventIsCreatedWithItsTimesSentInUTC() async throws {
        let (receipt, request) = try await self.send(
            .outlookCalendarCreateEvent(.init(subject: "Founders interview prep", body: "Go over the pitch",
                                              startRFC3339: "2026-09-17T20:00:00-05:00", endRFC3339: "2026-09-17T21:00:00-05:00")),
            status: 201, body: #"{"id":"EV1","subject":"Founders interview prep"}"#)
        XCTAssertEqual(receipt, .outlookCalendarEvent(id: "EV1"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://graph.microsoft.com/v1.0/me/events")
        let body = try self.json(request)
        XCTAssertEqual(body["subject"] as? String, "Founders interview prep")
        XCTAssertEqual((body["body"] as? [String: String])?["content"], "Go over the pitch")
        XCTAssertEqual(body["start"] as? [String: String], ["dateTime": "2026-09-18T01:00:00", "timeZone": "UTC"])
        XCTAssertEqual(body["end"] as? [String: String], ["dateTime": "2026-09-18T02:00:00", "timeZone": "UTC"])
    }

    func testChangingAnEventSendsOnlyTheFieldsGiven() async throws {
        let (receipt, request) = try await self.send(
            .outlookCalendarUpdateEvent(.init(eventID: "EV1", subject: "Interview prep (moved)", body: nil,
                                              startRFC3339: "2026-09-18T09:00:00Z", endRFC3339: "2026-09-18T09:30:00Z")),
            status: 200, body: #"{"id":"EV1"}"#)
        XCTAssertEqual(receipt, .outlookCalendarEvent(id: "EV1"))
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://graph.microsoft.com/v1.0/me/events/EV1")
        let body = try self.json(request)
        XCTAssertEqual(Set(body.keys), ["subject", "start", "end"])
        XCTAssertEqual(body["start"] as? [String: String], ["dateTime": "2026-09-18T09:00:00", "timeZone": "UTC"])
    }

    func testBadInputIsRefusedBeforeAnyRequest() async {
        let bad: [AccountWriteRequest] = [
            .outlookCalendarCreateEvent(.init(subject: " ", body: "", startRFC3339: "2026-09-17T20:00:00Z", endRFC3339: "2026-09-17T21:00:00Z")),
            .outlookCalendarCreateEvent(.init(subject: "Prep", body: "", startRFC3339: "2026-09-17T21:00:00Z", endRFC3339: "2026-09-17T20:00:00Z")),
            .outlookCalendarCreateEvent(.init(subject: "Prep", body: "", startRFC3339: "tonight", endRFC3339: "2026-09-17T21:00:00Z")),
            .outlookCalendarUpdateEvent(.init(eventID: "EV1", subject: nil, body: nil, startRFC3339: nil, endRFC3339: nil)),
            .outlookCalendarUpdateEvent(.init(eventID: "EV1", subject: nil, body: nil, startRFC3339: "2026-09-18T09:00:00Z", endRFC3339: nil)),
            .outlookCalendarUpdateEvent(.init(eventID: "../me", subject: "x", body: nil, startRFC3339: nil, endRFC3339: nil)),
        ]
        for input in bad {
            let transport = OutlookFixtureTransport(status: 200, body: "{}")
            let writer = DirectAccountWriter(transport: transport, bearer: { _ in "token" })
            do { _ = try await writer.writeAfterOwnerConfirmation(input); XCTFail("expected refusal") }
            catch { XCTAssertEqual(error as? AccountWriteError, .invalidRequest) }
            let calls = await transport.requests.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testAnAnswerWithoutAnEventIDIsNotTrusted() async {
        do {
            _ = try await self.send(.outlookCalendarCreateEvent(.init(subject: "Prep", body: "", startRFC3339: "2026-09-17T20:00:00Z", endRFC3339: "2026-09-17T21:00:00Z")),
                                    status: 201, body: #"{"subject":"Prep"}"#)
            XCTFail("expected refusal")
        } catch { XCTAssertEqual(error as? AccountWriteError, .outcomeUnknownNotSafeToRetry(operation: .outlookCalendarCreateEvent)) }
    }
}

private actor OutlookFixtureTransport: PhoneHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let status: Int
    private let body: String
    init(status: Int, body: String) { self.status = status; self.body = body }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
    }
}
