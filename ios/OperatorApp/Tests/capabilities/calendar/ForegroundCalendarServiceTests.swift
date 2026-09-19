import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundCalendarServiceTests: XCTestCase {
    func testUndecidedPermissionIsRequestedOnlyForCalendarInvocation() async throws {
        let store = RecordingCalendarStore(access: .notDetermined, events: [])
        let service = ForegroundCalendarService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(store.accessRequests, 1)
        XCTAssertEqual(store.eventRequests, 1)
        XCTAssertTrue((try payload(result)["events"] as? [[String: Any]])?.isEmpty == true)
    }

    func testDeniedPermissionDoesNotPromptOrReadEvents() async {
        let store = RecordingCalendarStore(access: .denied, events: [])
        let service = ForegroundCalendarService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "PERMISSION_DENIED", message: "Calendar permission was denied"))
        XCTAssertEqual(store.accessRequests, 0)
        XCTAssertEqual(store.eventRequests, 0)
    }

    func testDeniedPermissionPromptResultDoesNotReadEvents() async {
        let store = RecordingCalendarStore(access: .notDetermined, events: [], accessResult: false)
        let service = ForegroundCalendarService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "PERMISSION_DENIED", message: "Calendar permission was denied"))
        XCTAssertEqual(store.accessRequests, 1)
        XCTAssertEqual(store.eventRequests, 0)
    }

    func testAppBecomingInactiveDuringPermissionPromptDoesNotReadEvents() async {
        let activity = ActivityState(isActive: true)
        let store = RecordingCalendarStore(access: .notDetermined, events: [], onAccessRequest: { activity.isActive = false })
        let service = ForegroundCalendarService(store: store, isAppActive: { activity.isActive })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your calendar"))
        XCTAssertEqual(store.eventRequests, 0)
    }

    func testInactiveAppDoesNotPromptOrReadEvents() async {
        let store = RecordingCalendarStore(access: .notDetermined, events: [])
        let service = ForegroundCalendarService(store: store, isAppActive: { false })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your calendar"))
        XCTAssertEqual(store.accessRequests, 0)
        XCTAssertEqual(store.eventRequests, 0)
    }

    func testCalendarEventsReturnsSortedBoundedPayload() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = RecordingCalendarStore(access: .fullAccess, events: [
            .init(title: "Later", start: now.addingTimeInterval(120), end: now.addingTimeInterval(180), isAllDay: false),
            .init(title: "Sooner", start: now.addingTimeInterval(60), end: now.addingTimeInterval(90), isAllDay: true),
        ])
        let service = ForegroundCalendarService(store: store, now: { now }, isAppActive: { true })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        let events = try XCTUnwrap(try payload(result)["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["title"] as? String }, ["Sooner", "Later"])
        XCTAssertEqual(events.first?["allDay"] as? Bool, true)
        XCTAssertEqual(store.accessRequests, 0)
        XCTAssertEqual(store.eventRequests, 1)
    }

    func testCalendarEventsSortsBeforeApplyingLimit() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = (1 ... 25).map { offset in
            CalendarEvent(title: "Later \(offset)", start: now.addingTimeInterval(Double(offset * 60)), end: now, isAllDay: false)
        }
        let earliest = CalendarEvent(title: "Earliest", start: now.addingTimeInterval(-60), end: now, isAllDay: false)
        let store = RecordingCalendarStore(access: .fullAccess, events: later + [earliest])
        let service = ForegroundCalendarService(store: store, now: { now }, isAppActive: { true })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: nil)

        let events = try XCTUnwrap(try payload(result)["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 25)
        XCTAssertEqual(events.first?["title"] as? String, "Earliest")
        XCTAssertFalse(events.contains { $0["title"] as? String == "Later 25" })
    }

    func testParamsMustBeAnEmptyObject() async {
        let store = RecordingCalendarStore(access: .fullAccess, events: [])
        let service = ForegroundCalendarService(store: store, isAppActive: { true })

        let result = await service.handleNodeCommand("calendar.events", paramsJSON: #"{"days":30}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "calendar.events does not accept parameters"))
        XCTAssertEqual(store.eventRequests, 0)
    }

    private func payload(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case let .success(payloadJSON) = result else { throw NSError(domain: "test", code: 1) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
    }
}

@MainActor
private final class RecordingCalendarStore: CalendarEventStore {
    var access: CalendarAccess
    let events: [CalendarEvent]
    let accessResult: Bool
    let onAccessRequest: () -> Void
    private(set) var accessRequests = 0
    private(set) var eventRequests = 0

    init(access: CalendarAccess, events: [CalendarEvent], accessResult: Bool = true, onAccessRequest: @escaping () -> Void = {}) {
        self.access = access; self.events = events; self.accessResult = accessResult; self.onAccessRequest = onAccessRequest
    }
    func requestFullAccess() async -> Bool { accessRequests += 1; onAccessRequest(); if accessResult { access = .fullAccess }; return accessResult }
    func events(from: Date, to: Date, limit: Int) -> [CalendarEvent] { eventRequests += 1; return events }
}

@MainActor
private final class ActivityState { var isActive: Bool; init(isActive: Bool) { self.isActive = isActive } }
