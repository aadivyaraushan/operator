import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

final class ForegroundAccountReadServiceTests: XCTestCase {
    @MainActor
    func testMissingLimitExplainsHowToRetryWithoutRequestingCredentials() async {
        let service = ForegroundAccountReadService(reader: DirectAccountReader(bearer: { _ in
            XCTFail("missing limit must not request credentials")
            throw AccountReadError.notConnected
        }))
        for operation in ["googleCalendarEvents", "googleDriveFiles", "gmailMessages", "googleTasks", "outlookInbox", "outlookCalendarEvents", "slackChannels", "slackHistory", "spotifySearch", "spotifyPlayback"] {
            let result = await service.handleNodeCommand("connections.read", paramsJSON: "{\"operation\":\"\(operation)\"}", timeoutMilliseconds: nil)
            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "Missing required parameter: limit. Retry with an integer limit and the required parameters from connections.describe."), operation)
        }
    }

    @MainActor
    func testWrongTypeOptionalFieldsNeverRequestCredentials() async {
        let service = ForegroundAccountReadService(reader: DirectAccountReader(bearer: { _ in
            XCTFail("invalid input must not request credentials")
            throw AccountReadError.notConnected
        }))
        for field in ["query", "channel", "timeMin", "timeMax", "cursor"] {
            let result = await service.handleNodeCommand("connections.read", paramsJSON: "{\"operation\":\"spotifyPlayback\",\"limit\":1,\"\(field)\":true}", timeoutMilliseconds: nil)
            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "Connection read parameters were invalid"))
        }
    }

    @MainActor
    func testBecomingInactiveDuringReadDiscardsResults() async {
        let active = ActiveBox()
        let transport = ServiceTransport(body: #"{"items":[]}"#, beforeResponse: { await MainActor.run { active.value = false } })
        let service = ForegroundAccountReadService(reader: DirectAccountReader(transport: transport, bearer: { _ in "token" }), isAppActive: { active.value })
        let result = await service.handleNodeCommand("connections.read", paramsJSON: #"{"operation":"googleCalendarEvents","limit":1,"timeMin":"2026-09-09T00:00:00Z","timeMax":"2026-09-10T00:00:00Z"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read connected accounts"))
    }
    @MainActor
    func testStrictInputAndPostAwaitInactiveGuard() async {
        let transport = ServiceTransport(body: #"{"items":[{"id":"1","summary":"ok","secret":"drop"}]}"#)
        let active = ActiveBox()
        let service = ForegroundAccountReadService(reader: DirectAccountReader(transport: transport, bearer: { _ in "token" }), isAppActive: { active.value })
        let malformed = await service.handleNodeCommand("connections.read", paramsJSON: #"{"operation":"googleCalendarEvents","limit":true,"timeMin":"2026-09-09T00:00:00Z","timeMax":"2026-09-10T00:00:00Z"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(malformed, .failure(code: "INVALID_REQUEST", message: "Connection read parameters were invalid"))
        active.value = false
        let inactive = await service.handleNodeCommand("connections.read", paramsJSON: #"{"operation":"googleCalendarEvents","limit":1,"timeMin":"2026-09-09T00:00:00Z","timeMax":"2026-09-10T00:00:00Z"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(inactive, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read connected accounts"))
    }

    @MainActor
    func testServiceReturnsBoundedSanitizedPage() async {
        let transport = ServiceTransport(body: #"{"items":[{"id":"1","summary":"ok","secret":"drop"}]}"#)
        let service = ForegroundAccountReadService(reader: DirectAccountReader(transport: transport, bearer: { _ in "token" }))
        let result = await service.handleNodeCommand("connections.read", paramsJSON: #"{"operation":"googleCalendarEvents","limit":1,"timeMin":"2026-09-09T00:00:00Z","timeMax":"2026-09-10T00:00:00Z"}"#, timeoutMilliseconds: nil)
        guard case let .success(payload) = result else { return XCTFail("expected success") }
        XCTAssertTrue(payload.contains("summary")); XCTAssertFalse(payload.contains("secret"))
    }

    @MainActor
    func testCancelledCommandIsNotStarted() async {
        let service = ForegroundAccountReadService(reader: DirectAccountReader(bearer: { _ in XCTFail("cancelled command must not request a token"); return "token" }))
        let task = Task { @MainActor in
            await withTaskCancellationHandler(operation: {
                await service.handleNodeCommand("connections.read", paramsJSON: #"{"operation":"spotifyPlayback","limit":1}"#, timeoutMilliseconds: nil)
            }, onCancel: {})
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failure(code: "CANCELLED", message: "Connection read was cancelled"))
    }
    // Every account read is a network call and gmailMessages is up to eleven
    // of them. Before this the caller's only bound was URLSession's own
    // per-request default, which is a minute and applies per request rather
    // than to the operation.
    @MainActor
    func testASlowAccountReadTimesOutRatherThanWaiting() async {
        let transport = ServiceTransport(body: #"{"items":[]}"#, beforeResponse: {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        })
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let service = ForegroundAccountReadService(reader: reader, isAppActive: { true })

        let started = Date()
        let result = await service.handleNodeCommand(
            "connections.read",
            paramsJSON: #"{"operation":"googleCalendarEvents","timeMin":"2026-09-01T00:00:00Z","timeMax":"2026-09-08T00:00:00Z","limit":5}"#,
            timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "This account did not answer in time"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "waited well past the deadline")
    }

    @MainActor
    func testAnAbsentDeadlineStillCompletesNormally() async {
        let transport = ServiceTransport(body: #"{"items":[]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let service = ForegroundAccountReadService(reader: reader, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "connections.read",
            paramsJSON: #"{"operation":"googleCalendarEvents","timeMin":"2026-09-01T00:00:00Z","timeMax":"2026-09-08T00:00:00Z","limit":5}"#,
            timeoutMilliseconds: nil)

        guard case .success = result else { return XCTFail("a nil deadline must mean the default, not zero") }
    }

    // A timeout and a refusal are different things to tell an agent: one is
    // worth retrying, the other is not.
    @MainActor
    func testATimeoutIsDistinctFromAnAccountRefusal() async {
        let transport = ServiceTransport(body: #"{"ok":false,"error":"not_authed"}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let service = ForegroundAccountReadService(reader: reader, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "connections.read", paramsJSON: #"{"operation":"slackChannels","limit":2}"#, timeoutMilliseconds: 5_000)

        XCTAssertEqual(result, .failure(
            code: "ACCOUNT_UNAVAILABLE", message: "This account could not complete the read request"))
    }

    // A single request needs its own ceiling well inside the operation's, or
    // one hung call consumes the whole deadline on its own.
    func testASingleRequestCarriesItsOwnCeiling() {
        XCTAssertEqual(URLSessionPhoneHTTPTransport.requestTimeoutSeconds, 15)
        XCTAssertLessThan(
            URLSessionPhoneHTTPTransport.requestTimeoutSeconds,
            TimeInterval(GatewayDeadline.maximumMilliseconds) / 1_000,
            "a per-request ceiling at or above the operation deadline bounds nothing")
    }
}

private actor ServiceTransport: PhoneHTTPTransport {
    let body: String
    let beforeResponse: @Sendable () async -> Void
    init(body: String, beforeResponse: @escaping @Sendable () async -> Void = {}) { self.body = body; self.beforeResponse = beforeResponse }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await beforeResponse()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class ActiveBox { var value = true }
