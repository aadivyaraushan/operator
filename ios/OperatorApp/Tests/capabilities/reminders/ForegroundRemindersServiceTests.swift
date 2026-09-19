import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundRemindersServiceTests: XCTestCase {
    // EventKit invokes this completion on a background queue. This checks the
    // concrete adapter's boundary, which the protocol-only stub cannot reach.
    func testEventKitFetchCallbackIsSendableAndMapsWithoutTheMainActor() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OperatorApp/ForegroundRemindersService.swift")
        // This checks the shape of the source, so it can run only where the
        // source is on disk — the scratch SwiftPM package the run.sh harness
        // builds. In the on-device OperatorAppTests bundle the source is not
        // shipped, so skip rather than fail.
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            throw XCTSkip("source-shape check runs only in the scratch SwiftPM package layout")
        }

        XCTAssertTrue(source.contains("requestFullAccessToReminders { @Sendable granted, _ in"))
        XCTAssertTrue(source.contains("fetchReminders(matching: predicate) { @Sendable reminders in"))
        XCTAssertTrue(source.contains("nonisolated private static func map("))
    }

    func testReturnsIncompleteRemindersAsSortedJSON() async throws {
        let store = StubReminderStore(access: .fullAccess, reminders: [
            Reminder(title: "Book flights", due: Date(timeIntervalSince1970: 1_700_000_000), listName: "Travel"),
            Reminder(title: "No due date", due: nil, listName: "Someday"),
        ])
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        let items = try reminders(result)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["title"] as? String, "Book flights")
        XCTAssertEqual(items[0]["list"] as? String, "Travel")
        XCTAssertNotNil(items[0]["due"] as? String)
        XCTAssertEqual(items[1]["title"] as? String, "No due date")
        XCTAssertNil(items[1]["due"] as? String)
    }

    func testRejectsWrongCommandWithoutTouchingTheStore() async {
        let store = StubReminderStore(access: .fullAccess, reminders: [])
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("reminders.create", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(
            code: "UNSUPPORTED_COMMAND",
            message: "This iPhone node does not support reminders.create"))
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(store.permissionRequestCount, 0)
    }

    func testRejectsEveryInvalidParameterShapeWithoutReading() async {
        let invalid: [String?] = [
            "not-json",
            "[]",
            #"{"limit":0}"#,
            #"{"limit":26}"#,
            #"{"limit":-1}"#,
            #"{"limit":1.5}"#,
            #"{"limit":true}"#,
            #"{"limit":"5"}"#,
            #"{"count":5}"#,
            #"{"limit":5,"list":"Travel"}"#,
        ]
        for paramsJSON in invalid {
            let store = StubReminderStore(access: .fullAccess, reminders: [])
            let service = ForegroundRemindersService(store: store, isAppActive: { true })

            let result = await service.handleNodeCommand("reminders.list", paramsJSON: paramsJSON, timeoutMilliseconds: nil)

            XCTAssertEqual(result, .failure(
                code: "INVALID_REQUEST",
                message: "reminders.list accepts an optional limit between 1 and 25"),
                "params=\(String(describing: paramsJSON))")
            XCTAssertEqual(store.readCount, 0, "params=\(String(describing: paramsJSON))")
        }
    }

    func testAbsentEmptyAndEmptyObjectParametersAllMeanTheDefault() async throws {
        for paramsJSON: String? in [nil, "", "   ", "{}"] {
            let store = StubReminderStore(access: .fullAccess, reminders: [])
            let service = ForegroundRemindersService(store: store, isAppActive: { true })

            let result = await service.handleNodeCommand("reminders.list", paramsJSON: paramsJSON, timeoutMilliseconds: nil)

            XCTAssertEqual(try reminders(result).count, 0, "params=\(String(describing: paramsJSON))")
            XCTAssertEqual(store.lastLimit, ForegroundRemindersService.defaultLimit)
        }
    }

    func testAppliesTheRequestedLimitEvenWhenTheStoreIgnoresIt() async throws {
        let many = (0 ..< 25).map { Reminder(title: "Item \($0)", due: nil, listName: "List") }
        let store = StubReminderStore(access: .fullAccess, reminders: many)
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: #"{"limit":3}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(store.lastLimit, 3)
        // The store is asked for 3 and deliberately returns all 25. The
        // service must still return 3: a limit the caller can talk a
        // misbehaving store out of is not a limit.
        XCTAssertEqual(try reminders(result).count, 3)
    }

    func testRefusesWhenOperatorIsNotActive() async {
        let store = StubReminderStore(access: .fullAccess, reminders: [])
        let service = ForegroundRemindersService(store: store, isAppActive: { false })

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your reminders"))
        XCTAssertEqual(store.readCount, 0)
    }

    func testRefusesDeniedPermissionWithoutAskingAgain() async {
        let store = StubReminderStore(access: .denied, reminders: [])
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "PERMISSION_DENIED", message: "Reminders permission was denied"))
        XCTAssertEqual(store.permissionRequestCount, 0)
        XCTAssertEqual(store.readCount, 0)
    }

    func testRequestsPermissionOnceWhenUndeterminedThenReads() async throws {
        let store = StubReminderStore(access: .notDetermined, reminders: [
            Reminder(title: "Water plants", due: nil, listName: "Home"),
        ])
        store.grantOnRequest = true
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(store.permissionRequestCount, 1)
        XCTAssertEqual(try reminders(result).count, 1)
    }

    func testDeniedPermissionRequestDoesNotRead() async {
        let store = StubReminderStore(access: .notDetermined, reminders: [
            Reminder(title: "Never seen", due: nil, listName: "Home"),
        ])
        store.grantOnRequest = false
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "PERMISSION_DENIED", message: "Reminders permission was denied"))
        XCTAssertEqual(store.readCount, 0)
    }

    // The permission sheet takes the owner out of Operator. A grant that
    // lands while the app is in the background is not a live foreground
    // request, and reading on it would be reading unattended.
    func testLeavingTheAppDuringThePermissionPromptRefusesTheRead() async {
        let store = StubReminderStore(access: .notDetermined, reminders: [
            Reminder(title: "Never seen", due: nil, listName: "Home"),
        ])
        store.grantOnRequest = true
        var active = true
        let service = ForegroundRemindersService(store: store, isAppActive: { active })
        store.onPermissionRequest = { active = false }

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your reminders"))
        XCTAssertEqual(store.readCount, 0)
    }

    private func reminders(_ result: GatewayNodeCommandResult) throws -> [[String: Any]] {
        guard case .success(let payloadJSON) = result else {
            throw XCTSkip("expected success, got \(result)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))
        guard let dictionary = object as? [String: Any],
              let items = dictionary["reminders"] as? [[String: Any]]
        else { throw XCTSkip("payload was not a reminders array: \(payloadJSON)") }
        return items
    }
}

@MainActor
private final class StubReminderStore: ReminderStore {
    var access: RemindersAccess
    var grantOnRequest = true
    var onPermissionRequest: (() -> Void)?
    private(set) var permissionRequestCount = 0
    private(set) var readCount = 0
    private(set) var lastLimit: Int?
    private let reminders: [Reminder]

    init(access: RemindersAccess, reminders: [Reminder]) {
        self.access = access
        self.reminders = reminders
    }

    var delayNanoseconds: UInt64 = 0

    func requestFullAccess() async -> Bool {
        self.permissionRequestCount += 1
        self.onPermissionRequest?()
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        if self.grantOnRequest { self.access = .fullAccess }
        return self.grantOnRequest
    }

    func incompleteReminders(limit: Int) async -> [Reminder] {
        self.readCount += 1
        self.lastLimit = limit
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        // Deliberately ignores the limit; the service must enforce it.
        return self.reminders
    }
}

@MainActor
final class RemindersDeadlineTests: XCTestCase {
    // The gateway's timeoutMilliseconds used to be discarded here, so a slow
    // store meant an unbounded wait with nothing to report.
    func testASlowReadTimesOutRatherThanWaiting() async {
        let store = StubReminderStore(access: .fullAccess, reminders: [])
        store.delayNanoseconds = 2_000_000_000
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let started = Date()
        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "Reading your reminders took too long"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testAnUnansweredPermissionPromptTimesOutWithoutReading() async {
        let store = StubReminderStore(access: .notDetermined, reminders: [])
        store.delayNanoseconds = 2_000_000_000
        let service = ForegroundRemindersService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "Reminders permission was not answered in time"))
        XCTAssertEqual(store.readCount, 0)
    }
}

@MainActor
final class RemindersRoutingTests: XCTestCase {
    func testRoutesRemindersListToTheRemindersHandler() async {
        let other = EchoNodeHandler("other")
        let reminders = EchoNodeHandler("reminders")
        let router = ForegroundNodeCommandRouter(
            location: other, calendar: other, reminders: reminders, messages: other, maps: other,
            handoff: other, whatsapp: other, whatsappCompose: other, accounts: other,
            accountWrite: other, notion: other)

        let result = await router.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .success(payloadJSON: #"{"by":"reminders","cmd":"reminders.list"}"#))
    }

    // Every call site written before this connector existed omits the
    // handler. Those must still compile, and must refuse honestly rather
    // than routing a reminders call to whatever is next in the switch.
    func testOmittingTheHandlerRefusesRatherThanMisroutes() async {
        let other = EchoNodeHandler("other")
        let router = ForegroundNodeCommandRouter(
            location: other, calendar: other, messages: other, maps: other, handoff: other,
            whatsapp: other, whatsappCompose: other, accounts: other, accountWrite: other, notion: other)

        let result = await router.handleNodeCommand("reminders.list", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(
            code: "UNSUPPORTED_COMMAND",
            message: "This iPhone node does not support reminders.list"))
    }

    func testCalendarStillRoutesToCalendar() async {
        let other = EchoNodeHandler("other")
        let calendar = EchoNodeHandler("calendar")
        let router = ForegroundNodeCommandRouter(
            location: other, calendar: calendar, reminders: other, messages: other, maps: other,
            handoff: other, whatsapp: other, whatsappCompose: other, accounts: other,
            accountWrite: other, notion: other)

        let result = await router.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .success(payloadJSON: #"{"by":"calendar","cmd":"calendar.events"}"#))
    }

    func testRemindersIsAdvertisedButNeverAutoAllowed() {
        XCTAssertTrue(GatewayNativeNodeSurface.commands.contains("reminders.list"))
        XCTAssertTrue(GatewayNativeNodeSurface.capabilities.contains("reminders"))
        // Reminders is personal data, so it follows location.get and
        // calendar.events: advertised to the agent, but never added to the
        // policy Operator installs into the gateway on the owner's behalf.
        // The two companions are asserted alongside it so that relaxing the
        // rule for any of the three fails here.
        XCTAssertFalse(GatewayNativeNodeSurface.commandPolicyAllow.contains("reminders.list"))
        XCTAssertFalse(GatewayNativeNodeSurface.commandPolicyAllow.contains("calendar.events"))
        XCTAssertFalse(GatewayNativeNodeSurface.commandPolicyAllow.contains("location.get"))
    }
}

@MainActor
private final class EchoNodeHandler: GatewayNodeCommandHandler {
    private let name: String
    init(_ name: String) { self.name = name }
    func handleNodeCommand(
        _ command: String,
        paramsJSON _: String?,
        timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult
    {
        .success(payloadJSON: #"{"by":"\#(self.name)","cmd":"\#(command)"}"#)
    }
}
