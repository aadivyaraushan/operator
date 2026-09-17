import Foundation
import XCTest
@testable import OperatorApp

/// The owner asked Operator to "add a task" and was told Google Tasks was
/// read-only. These cover adding a task and changing or completing one.
final class GoogleTasksWriterTests: XCTestCase {
    private func send(_ input: AccountWriteRequest, body: String) async throws -> (AccountWriteReceipt, URLRequest) {
        let transport = TasksFixtureTransport(body: body)
        let writer = DirectAccountWriter(transport: transport, bearer: { _ in "token" })
        let receipt = try await writer.writeAfterOwnerConfirmation(input)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        return (receipt, try XCTUnwrap(requests.first))
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testGoogleScopeAllowsChangingTasks() {
        let scopes = OAuthProvider.google.scopes
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/tasks"))
        XCTAssertFalse(scopes.contains("https://www.googleapis.com/auth/tasks.readonly"))
    }

    func testATaskIsAddedToTheDefaultListWithItsNotesAndDueDay() async throws {
        let (receipt, request) = try await self.send(
            .googleTasksCreateTask(.init(list: nil, title: "Finish connectors", notes: "on Operator", due: "2026-09-20")),
            body: #"{"id":"T1","title":"Finish connectors"}"#)
        XCTAssertEqual(receipt, .googleTask(id: "T1"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "tasks.googleapis.com")
        XCTAssertEqual(request.url?.path, "/tasks/v1/lists/@default/tasks")
        let body = try self.json(request)
        XCTAssertEqual(body["title"] as? String, "Finish connectors")
        XCTAssertEqual(body["notes"] as? String, "on Operator")
        XCTAssertEqual(body["due"] as? String, "2026-09-20T00:00:00.000Z")
    }

    func testATaskWithOnlyATitleSendsNothingElse() async throws {
        let (_, request) = try await self.send(
            .googleTasksCreateTask(.init(list: "L1", title: "Call mum", notes: nil, due: nil)), body: #"{"id":"T2"}"#)
        XCTAssertEqual(request.url?.path, "/tasks/v1/lists/L1/tasks")
        XCTAssertEqual(Set(try self.json(request).keys), ["title"])
    }

    func testCompletingATaskChangesOnlyItsStatus() async throws {
        let (receipt, request) = try await self.send(
            .googleTasksUpdateTask(.init(list: nil, taskID: "T1", title: nil, notes: nil, due: nil, completed: true)),
            body: #"{"id":"T1","status":"completed"}"#)
        XCTAssertEqual(receipt, .googleTask(id: "T1"))
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/tasks/v1/lists/@default/tasks/T1")
        XCTAssertEqual(try self.json(request) as? [String: String], ["status": "completed"])
    }

    func testReopeningATaskSetsItBackToNeedsAction() async throws {
        let (_, request) = try await self.send(
            .googleTasksUpdateTask(.init(list: nil, taskID: "T1", title: "New title", notes: nil, due: nil, completed: false)),
            body: #"{"id":"T1"}"#)
        XCTAssertEqual(try self.json(request) as? [String: String], ["title": "New title", "status": "needsAction"])
    }

    func testBadInputIsRefusedBeforeAnyRequest() async {
        let bad: [AccountWriteRequest] = [
            .googleTasksCreateTask(.init(list: nil, title: "", notes: nil, due: nil)),
            .googleTasksCreateTask(.init(list: nil, title: "x", notes: nil, due: "tomorrow")),
            .googleTasksCreateTask(.init(list: "a/b", title: "x", notes: nil, due: nil)),
            .googleTasksUpdateTask(.init(list: nil, taskID: "../x", title: "x", notes: nil, due: nil, completed: nil)),
            .googleTasksUpdateTask(.init(list: nil, taskID: "T1", title: nil, notes: nil, due: nil, completed: nil)),
        ]
        for input in bad {
            let transport = TasksFixtureTransport(body: "{}")
            let writer = DirectAccountWriter(transport: transport, bearer: { _ in "token" })
            do { _ = try await writer.writeAfterOwnerConfirmation(input); XCTFail("expected refusal") }
            catch { XCTAssertEqual(error as? AccountWriteError, .invalidRequest) }
            let calls = await transport.requests.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testAnAnswerForADifferentTaskIsNotAccepted() async {
        do {
            _ = try await self.send(.googleTasksUpdateTask(.init(list: nil, taskID: "T1", title: "x", notes: nil, due: nil, completed: nil)), body: #"{"id":"OTHER"}"#)
            XCTFail("expected refusal")
        } catch { XCTAssertEqual(error as? AccountWriteError, .outcomeUnknownNotSafeToRetry(operation: .googleTasksUpdateTask)) }
    }
}

private actor TasksFixtureTransport: PhoneHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let body: String
    init(body: String) { self.body = body }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
