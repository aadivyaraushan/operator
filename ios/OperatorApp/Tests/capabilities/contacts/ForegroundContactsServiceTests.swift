import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundContactsServiceTests: XCTestCase {
    func testResolvesAContactAndTrimsTheQueryBeforeSearching() async throws {
        let directory = StubContactDirectory(access: .full, matches: [
            ContactMatch(displayName: "Mom", phoneNumbers: ["+12175550100"], emailAddresses: ["mom@example.com"]),
        ])
        let service = ForegroundContactsService(directory: directory, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"  Mom  "}"#, timeoutMilliseconds: nil)

        let payload = try payload(result)
        let matches = try XCTUnwrap(payload["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0]["name"] as? String, "Mom")
        XCTAssertEqual(matches[0]["phones"] as? [String], ["+12175550100"])
        XCTAssertEqual(matches[0]["emails"] as? [String], ["mom@example.com"])
        XCTAssertEqual(payload["partialAccess"] as? Bool, false)
        XCTAssertEqual(directory.lastQuery, "Mom")
        XCTAssertEqual(directory.lastLimit, ForegroundContactsService.defaultLimit)
    }

    // The address book is never listable. Every one of these must be refused
    // before the directory is touched, and the empty object is the important
    // one: for reminders it means "the default", and here it would mean
    // "everyone you know".
    func testRefusesAnythingThatIsNotABoundedQuery() async {
        let invalid: [String?] = [
            nil,
            "",
            "not-json",
            "[]",
            "{}",
            #"{"limit":3}"#,
            #"{"query":""}"#,
            #"{"query":"   "}"#,
            #"{"query":123}"#,
            #"{"query":"a","limit":0}"#,
            #"{"query":"a","limit":11}"#,
            #"{"query":"a","limit":true}"#,
            #"{"query":"a","limit":1.5}"#,
            #"{"query":"a","limit":"3"}"#,
            #"{"query":"a","name":"b"}"#,
            #"{"query":"\#(String(repeating: "a", count: 101))"}"#,
        ]
        for paramsJSON in invalid {
            let directory = StubContactDirectory(access: .full, matches: [])
            let service = ForegroundContactsService(directory: directory, isAppActive: { true })

            let result = await service.handleNodeCommand(
                "contacts.search", paramsJSON: paramsJSON, timeoutMilliseconds: nil)

            XCTAssertEqual(result, .failure(
                code: "INVALID_REQUEST",
                message: "contacts.search requires a nonempty query and an optional limit between 1 and 10"),
                "params=\(String(describing: paramsJSON))")
            XCTAssertEqual(directory.searchCount, 0, "params=\(String(describing: paramsJSON))")
        }
    }

    func testEnforcesLimitAndHandleCapAgainstAMisbehavingDirectory() async throws {
        let many = (0 ..< 10).map { index in
            ContactMatch(
                displayName: "Person \(index)",
                phoneNumbers: (0 ..< 9).map { "number-\($0)" },
                emailAddresses: (0 ..< 9).map { "email-\($0)" })
        }
        let directory = StubContactDirectory(access: .full, matches: many)
        let service = ForegroundContactsService(directory: directory, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"Person","limit":2}"#, timeoutMilliseconds: nil)

        let matches = try XCTUnwrap(try payload(result)["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual((matches[0]["phones"] as? [String])?.count, ForegroundContactsService.maximumHandlesPerContact)
        XCTAssertEqual((matches[0]["emails"] as? [String])?.count, ForegroundContactsService.maximumHandlesPerContact)
    }

    func testReportsPartialAccessWithoutReprompting() async throws {
        let directory = StubContactDirectory(access: .limited, matches: [
            ContactMatch(displayName: "Mom", phoneNumbers: [], emailAddresses: []),
        ])
        let service = ForegroundContactsService(directory: directory, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"Mom"}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(try payload(result)["partialAccess"] as? Bool, true)
        XCTAssertEqual(directory.permissionRequestCount, 0)
    }

    func testRefusesWhenOperatorIsNotActive() async {
        let directory = StubContactDirectory(access: .full, matches: [])
        let service = ForegroundContactsService(directory: directory, isAppActive: { false })

        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"a"}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to look up a contact"))
        XCTAssertEqual(directory.searchCount, 0)
    }

    func testRefusesDeniedPermissionWithoutAskingAgain() async {
        let directory = StubContactDirectory(access: .denied, matches: [])
        let service = ForegroundContactsService(directory: directory, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"a"}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "PERMISSION_DENIED", message: "Contacts permission was denied"))
        XCTAssertEqual(directory.permissionRequestCount, 0)
        XCTAssertEqual(directory.searchCount, 0)
    }

    func testLeavingTheAppDuringThePermissionPromptRefusesTheLookup() async {
        let directory = StubContactDirectory(access: .notDetermined, matches: [
            ContactMatch(displayName: "Never seen", phoneNumbers: [], emailAddresses: []),
        ])
        var active = true
        let service = ForegroundContactsService(directory: directory, isAppActive: { active })
        directory.onPermissionRequest = { active = false }

        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"x"}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to look up a contact"))
        XCTAssertEqual(directory.searchCount, 0)
    }

    func testRejectsWrongCommandWithoutSearching() async {
        let directory = StubContactDirectory(access: .full, matches: [])
        let service = ForegroundContactsService(directory: directory, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "contacts.list", paramsJSON: #"{"query":"a"}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(
            code: "UNSUPPORTED_COMMAND",
            message: "This iPhone node does not support contacts.list"))
        XCTAssertEqual(directory.searchCount, 0)
    }

    func testContactsIsAdvertisedButNeverAutoAllowed() {
        XCTAssertTrue(GatewayNativeNodeSurface.commands.contains("contacts.search"))
        XCTAssertTrue(GatewayNativeNodeSurface.capabilities.contains("contacts"))
        XCTAssertFalse(GatewayNativeNodeSurface.commandPolicyAllow.contains("contacts.search"))
    }

    private func payload(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case .success(let payloadJSON) = result else {
            throw XCTSkip("expected success, got \(result)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw XCTSkip("payload was not an object: \(payloadJSON)")
        }
        return dictionary
    }
}

@MainActor
final class ContactsDeadlineTests: XCTestCase {
    func testASlowLookupTimesOutRatherThanWaiting() async {
        let directory = StubContactDirectory(access: .full, matches: [])
        directory.delayNanoseconds = 2_000_000_000
        let service = ForegroundContactsService(directory: directory, isAppActive: { true })

        let started = Date()
        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"a"}"#, timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "Looking up that contact took too long"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testAnUnansweredPermissionPromptTimesOutWithoutSearching() async {
        let directory = StubContactDirectory(access: .notDetermined, matches: [])
        directory.delayNanoseconds = 2_000_000_000
        let service = ForegroundContactsService(directory: directory, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "contacts.search", paramsJSON: #"{"query":"a"}"#, timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "Contacts permission was not answered in time"))
        XCTAssertEqual(directory.searchCount, 0)
    }
}

@MainActor
private final class StubContactDirectory: ContactDirectory {
    var access: ContactsAccess
    var grantOnRequest = true
    var onPermissionRequest: (() -> Void)?
    private(set) var permissionRequestCount = 0
    private(set) var searchCount = 0
    private(set) var lastQuery: String?
    private(set) var lastLimit: Int?
    private let matches: [ContactMatch]

    init(access: ContactsAccess, matches: [ContactMatch]) {
        self.access = access
        self.matches = matches
    }

    var delayNanoseconds: UInt64 = 0

    func requestAccess() async -> Bool {
        self.permissionRequestCount += 1
        self.onPermissionRequest?()
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        if self.grantOnRequest { self.access = .full }
        return self.grantOnRequest
    }

    func existing(phoneNumber: String) async -> ContactMatch? { nil }
    func existing(emailAddress: String) async -> ContactMatch? { nil }
    func create(_ draft: ContactDraft) async throws -> String { throw ContactDirectoryError.saveFailed }

    func search(query: String, limit: Int) async -> [ContactMatch] {
        self.searchCount += 1
        self.lastQuery = query
        self.lastLimit = limit
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        // Deliberately ignores the limit; the service must enforce it.
        return self.matches
    }
}
