import EventKit
import Foundation
import OperatorCore
import OSLog
import UIKit

enum CalendarAccess: Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
}

struct CalendarEvent: Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

@MainActor
protocol CalendarEventStore: AnyObject {
    var access: CalendarAccess { get }
    func requestFullAccess() async -> Bool
    func events(from: Date, to: Date, limit: Int) -> [CalendarEvent]
}

@MainActor
final class ForegroundCalendarService: GatewayNodeCommandHandler {
    private struct Payload: Encodable {
        struct Event: Encodable {
            let title: String
            let start: String
            let end: String
            let allDay: Bool
        }
        let events: [Event]
    }

    private let store: any CalendarEventStore
    private let now: @MainActor @Sendable () -> Date
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-calendar")

    convenience init() { self.init(store: EventKitCalendarStore()) }

    init(
        store: any CalendarEventStore,
        now: @escaping @MainActor @Sendable () -> Date = Date.init,
        isAppActive: @escaping @MainActor @Sendable () -> Bool = {
            UIApplication.shared.applicationState == .active
        })
    {
        self.store = store
        self.now = now
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "calendar.events" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard Self.acceptsEmptyObject(paramsJSON) else {
            return .failure(code: "INVALID_REQUEST", message: "calendar.events does not accept parameters")
        }
        guard self.isAppActive() else {
            self.logger.info("[calendar] rejected request while app was not active")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your calendar")
        }
        if self.store.access == .denied {
            self.logger.info("[calendar] permission already denied")
            return .failure(code: "PERMISSION_DENIED", message: "Calendar permission was denied")
        }
        if self.store.access == .notDetermined {
            let granted = await self.store.requestFullAccess()
            guard self.isAppActive() else {
                self.logger.info("[calendar] app became inactive while permission was requested")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your calendar")
            }
            guard granted else {
                self.logger.info("[calendar] permission request was denied")
                return .failure(code: "PERMISSION_DENIED", message: "Calendar permission was denied")
            }
        }

        let start = self.now()
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else {
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not read your calendar")
        }
        let events = self.store.events(from: start, to: end, limit: 25)
            .sorted { $0.start < $1.start }
            .prefix(25)
            .map { event in
                Payload.Event(
                    title: event.title,
                    start: ISO8601DateFormatter().string(from: event.start),
                    end: ISO8601DateFormatter().string(from: event.end),
                    allDay: event.isAllDay)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(events: Array(events))),
              let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[calendar] failed to encode event count=\(events.count)")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not read your calendar")
        }
        self.logger.info("[calendar] returned event count=\(events.count)")
        return .success(payloadJSON: payloadJSON)
    }

    private static func acceptsEmptyObject(_ paramsJSON: String?) -> Bool {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any]
        else { return false }
        return object.isEmpty
    }
}

@MainActor
final class EventKitCalendarStore: CalendarEventStore {
    private let store = EKEventStore()

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestFullAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            // Called back off the main actor; see the note in
            // ForegroundRemindersService for why this must be @Sendable.
            self.store.requestFullAccessToEvents { @Sendable granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func events(from: Date, to: Date, limit: Int) -> [CalendarEvent] {
        let predicate = self.store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return self.store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(limit).map {
            CalendarEvent(title: $0.title, start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
    }
}
