import XCTest
@testable import OperatorApp

@MainActor final class ForegroundAccountWriteConfirmationServiceTests: XCTestCase {
    func testRejectsUnknownKeysAndWrongTypesBeforePrompt() async {
        let presenter = FakePresenter(); let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        for value in [#"{"operation":"slackPostMessage","channelID":"C123","text":"hi","extra":1}"#, #"{"operation":"slackPostMessage","channelID":true,"text":"hi"}"#] {
            let result = await service.handleNodeCommand("connections.write", paramsJSON: value, timeoutMilliseconds: nil)
            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "Connection write parameters were invalid"))
        }
        let invalidCalls = await writer.callCount()
        XCTAssertEqual(presenter.requests.count, 0); XCTAssertEqual(invalidCalls, 0)
    }

    func testConfirmsImmutablePreviewThenWritesExactlyOnce() async {
        let presenter = FakePresenter(); let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        let json = #"{"operation":"slackPostMessage","channelID":"C123","text":"hello"}"#
        let result = await service.handleNodeCommand("connections.write", paramsJSON: json, timeoutMilliseconds: 1000)
        let calls = await writer.callCount()
        let last = await writer.lastRequest()
        XCTAssertEqual(result, .success(payloadJSON: #"{"ok":true,"operation":"slackPostMessage","receipt":{"kind":"slackMessage","channelID":"C123","timestamp":"1"}}"#)); XCTAssertEqual(calls, 1)
        XCTAssertEqual(presenter.requests.first?.preview, "Slack channel C123\nMessage: hello")
        XCTAssertEqual(last?.operation, .slackPostMessage)
    }

    func testDenialInactiveAndTimeoutPerformZeroWrites() async {
        let presenter = FakePresenter(); presenter.allow = false; let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        let denied = await service.handleNodeCommand("connections.write", paramsJSON: #"{"operation":"slackPostMessage","channelID":"C123","text":"hello"}"#, timeoutMilliseconds: 100)
        XCTAssertEqual(denied, .failure(code: "OWNER_DENIED", message: "The account write was not performed"))
        let deniedCalls = await writer.callCount()
        XCTAssertEqual(deniedCalls, 0)

        let inactive = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { false })
        let result = await inactive.handleNodeCommand("connections.write", paramsJSON: #"{"operation":"slackPostMessage","channelID":"C123","text":"hello"}"#, timeoutMilliseconds: nil)
        let inactiveCalls = await writer.callCount()
        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to confirm the account write")); XCTAssertEqual(inactiveCalls, 0)
    }

    func testTimeoutIsDistinctFromOwnerDenial() async {
        let presenter = FakePresenter(); presenter.hang = true; let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        let result = await service.handleNodeCommand("connections.write", paramsJSON: #"{"operation":"slackPostMessage","channelID":"C123","text":"hello"}"#, timeoutMilliseconds: 300)
        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "The account write preview expired"))
        let calls = await writer.callCount(); XCTAssertEqual(calls, 0)
    }

    func testTaskCancellationIsDistinctAndWritesNothing() async {
        let presenter = FakePresenter(); presenter.hang = true; let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        let task = Task { await service.handleNodeCommand("connections.write", paramsJSON: #"{"operation":"slackPostMessage","channelID":"C123","text":"hello"}"#, timeoutMilliseconds: 30_000) }
        task.cancel(); let result = await task.value
        XCTAssertEqual(result, .failure(code: "CANCELLED", message: "The account write was cancelled"))
        let calls = await writer.callCount(); XCTAssertEqual(calls, 0)
    }

    func testASheetEditShowsEveryCellOnTheCardAndRefusesCellsThatAreNotText() async {
        let presenter = FakePresenter(); let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        _ = await service.handleNodeCommand("connections.write", paramsJSON: #"{"operation":"googleSheetsAppendRows","fileID":"S1","range":"Signups","rows":[["a@example.com","mon"],["b@example.com","tue"]]}"#, timeoutMilliseconds: 1000)
        XCTAssertEqual(presenter.requests.first?.preview, "Add 2 rows to Signups in Google Sheet S1\na@example.com | mon\nb@example.com | tue")
        let last = await writer.lastRequest()
        XCTAssertEqual(last?.operation, .googleSheetsAppendRows)

        for bad in [#"{"operation":"googleSheetsUpdateCells","fileID":"S1","range":"A1","rows":[[1,2]]}"#,
                    #"{"operation":"googleSheetsUpdateCells","fileID":"S1","range":"A1","rows":"x"}"#,
                    #"{"operation":"googleDriveCreateFile","name":"Plan","kind":"pdf"}"#,
                    #"{"operation":"googleDocsReplaceText","fileID":"D1","find":"a"}"#] {
            let result = await service.handleNodeCommand("connections.write", paramsJSON: bad, timeoutMilliseconds: 1000)
            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "Connection write parameters were invalid"), bad)
        }
        let calls = await writer.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testOptionalKeysMayBeAbsentOrNullButNeverTheWrongType() async {
        let presenter = FakePresenter(); let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        let accepted = [
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1","summary":"Moved"}"#,
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1","summary":null,"attendees":["a@example.com"]}"#,
            #"{"operation":"googleCalendarCreateEvent","summary":"Plan","description":"","startRFC3339":"2026-01-01T10:00:00Z","endRFC3339":"2026-01-01T11:00:00Z","attendees":["a@example.com"]}"#,
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1","addMeetLink":true}"#,
            #"{"operation":"googleCalendarCreateEvent","summary":"Plan","description":"","startRFC3339":"2026-01-01T10:00:00Z","endRFC3339":"2026-01-01T11:00:00Z","addMeetLink":true}"#,
        ]
        for value in accepted {
            let result = await service.handleNodeCommand("connections.write", paramsJSON: value, timeoutMilliseconds: 1000)
            guard case .success = result else { return XCTFail("\(value) -> \(result)") }
        }
        XCTAssertEqual(presenter.requests.map(\.preview), [
            "Update calendar event ev1\nSummary: Moved",
            "Update calendar event ev1\nGuest list becomes: a@example.com",
            "Calendar event\nSummary: Plan\nStarts: 2026-01-01T10:00:00Z\nEnds: 2026-01-01T11:00:00Z\nDescription: \nInvites sent to: a@example.com",
            "Update calendar event ev1\nGoogle Meet link: added",
            "Calendar event\nSummary: Plan\nStarts: 2026-01-01T10:00:00Z\nEnds: 2026-01-01T11:00:00Z\nDescription: \nGoogle Meet link: added",
        ])
        let rejected = [
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1","summary":7}"#,
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1","attendees":"a@example.com"}"#,
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1"}"#,
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1","addMeetLink":false}"#,
            #"{"operation":"googleCalendarUpdateEvent","eventID":"ev1","addMeetLink":"yes"}"#,
            #"{"operation":"googleCalendarUpdateEvent","summary":"Moved"}"#,
            #"{"operation":"googleCalendarCreateEvent","summary":"Plan","description":"","startRFC3339":"2026-01-01T10:00:00Z","endRFC3339":"2026-01-01T11:00:00Z","attendees":[1]}"#,
        ]
        let before = await writer.callCount()
        for value in rejected {
            let result = await service.handleNodeCommand("connections.write", paramsJSON: value, timeoutMilliseconds: nil)
            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "Connection write parameters were invalid"), value)
        }
        let after = await writer.callCount()
        XCTAssertEqual(after, before)
    }

    func testInvalidTypedRequestIsRejectedBeforePrompt() async {
        let presenter = FakePresenter(); let writer = FakeWriter()
        let service = ForegroundAccountWriteConfirmationService(writer: writer, presenter: presenter, isAppActive: { true })
        let result = await service.handleNodeCommand("connections.write", paramsJSON: #"{"operation":"googleCalendarCreateEvent","summary":"","description":"x","startRFC3339":"2026-01-02T00:00:00Z","endRFC3339":"2026-01-01T00:00:00Z"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "Connection write parameters were invalid"))
        XCTAssertTrue(presenter.requests.isEmpty)
        let calls = await writer.callCount()
        XCTAssertEqual(calls, 0)
    }
}

@MainActor private final class FakePresenter: AccountWriteConfirmationPresenting {
    var allow = true
    var hang = false
    var requests: [AccountWriteConfirmationRequest] = []
    func confirm(_ request: AccountWriteConfirmationRequest) async -> AccountWriteDecision { requests.append(request); if hang { try? await Task.sleep(for: .seconds(60)) }; return allow ? .confirmed(request) : .denied }
    func cancel() {}
}

private actor FakeWriter: AccountWriteExecuting {
    var calls = 0; var last: AccountWriteRequest?
    func writeAfterOwnerConfirmation(_ input: AccountWriteRequest) async throws -> AccountWriteReceipt { calls += 1; last = input; return .slackMessage(channelID: "C123", timestamp: "1") }
    func callCount() -> Int { calls }
    func lastRequest() -> AccountWriteRequest? { last }
}
