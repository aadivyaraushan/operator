import EventKit
import Foundation
import OperatorCore
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// Reminders is the calendar service's twin, and deliberately so: same
// framework, same permission shape, same foreground rule, same refusal
// vocabulary. Where it differs from calendar it is because EventKit itself
// differs — reminders are fetched through a completion handler rather than
// returned synchronously, so the store protocol is async.
//
// It reads incomplete reminders only. A completed reminder is a record of
// something already dealt with; including them would make every list longer
// and less useful without telling the owner anything they asked for.

enum RemindersAccess: Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
}

struct Reminder: Sendable, Equatable {
    let title: String
    let due: Date?
    let listName: String
}

@MainActor
protocol ReminderStore: AnyObject, Sendable {
    var access: RemindersAccess { get }
    func requestFullAccess() async -> Bool
    func incompleteReminders(limit: Int) async -> [Reminder]
}

@MainActor
final class ForegroundRemindersService: GatewayNodeCommandHandler {
    /// The most reminders one call may return. A reminder list is unbounded
    /// in a way a week of calendar events is not, so the cap is the only
    /// thing standing between "what am I meant to be doing" and several
    /// hundred rows of someone's backlog in a chat transcript.
    static let maximumLimit = 25
    static let defaultLimit = 25

    private struct Payload: Encodable {
        struct Item: Encodable {
            let title: String
            let due: String?
            let list: String
        }

        let reminders: [Item]
    }

    private let store: any ReminderStore
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-reminders")

    init(
        store: any ReminderStore,
        isAppActive: @escaping @MainActor @Sendable () -> Bool)
    {
        self.store = store
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "reminders.list" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let limit = Self.limit(from: paramsJSON) else {
            self.logger.info("[reminders] refused branch=invalid_params")
            return .failure(
                code: "INVALID_REQUEST",
                message: "reminders.list accepts an optional limit between 1 and \(Self.maximumLimit)")
        }
        guard self.isAppActive() else {
            self.logger.info("[reminders] refused branch=app_not_active")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your reminders")
        }
        // One deadline covers the permission prompt and the read together.
        // An owner who never answers the prompt is the realistic way this
        // hangs, so bounding only the read would bound the wrong half.
        let deadline = Date().addingTimeInterval(Double(GatewayDeadline.bounded(timeoutMilliseconds)) / 1_000)
        if self.store.access == .denied {
            self.logger.info("[reminders] refused branch=permission_denied")
            return .failure(code: "PERMISSION_DENIED", message: "Reminders permission was denied")
        }
        if self.store.access == .notDetermined {
            guard let granted = await GatewayDeadline.run(
                milliseconds: Int(deadline.timeIntervalSinceNow * 1_000),
                { [store] in await store.requestFullAccess() })
            else {
                self.logger.info("[reminders] refused branch=permission_timeout")
                return .failure(code: "TIMEOUT", message: "Reminders permission was not answered in time")
            }
            // Re-checked after the await for the same reason the calendar
            // service re-checks: the permission sheet takes the owner out of
            // the app, and a grant that arrives while Operator is in the
            // background must not be treated as a live foreground request.
            guard self.isAppActive() else {
                self.logger.info("[reminders] refused branch=app_left_during_permission")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your reminders")
            }
            guard granted else {
                self.logger.info("[reminders] refused branch=permission_request_denied")
                return .failure(code: "PERMISSION_DENIED", message: "Reminders permission was denied")
            }
        }

        guard let fetched = await GatewayDeadline.run(
            milliseconds: Int(deadline.timeIntervalSinceNow * 1_000),
            { [store] in await store.incompleteReminders(limit: limit) })
        else {
            self.logger.info("[reminders] refused branch=read_timeout")
            return .failure(code: "TIMEOUT", message: "Reading your reminders took too long")
        }
        let formatter = ISO8601DateFormatter()
        let items = fetched
            .prefix(limit)
            .map { reminder in
                Payload.Item(
                    title: reminder.title,
                    due: reminder.due.map(formatter.string(from:)),
                    list: reminder.listName)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(reminders: Array(items))),
              let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[reminders] failed branch=encode count=\(items.count)")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not read your reminders")
        }
        self.logger.info("[reminders] returned count=\(items.count)")
        return .success(payloadJSON: payloadJSON)
    }

    /// Returns the limit to use, or nil if the parameters are not acceptable.
    /// Absent, empty and `{}` all mean the default; anything else must be an
    /// object carrying nothing but an in-range integer `limit`.
    static func limit(from paramsJSON: String?) -> Int? {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.defaultLimit
        }
        guard paramsJSON.utf8.count <= 4096,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["limit"])
        else { return nil }
        guard let raw = object["limit"] else { return Self.defaultLimit }
        return JSONNumber.integer(raw, in: 1 ... Self.maximumLimit)
    }
}

@MainActor
final class EventKitReminderStore: ReminderStore {
    private let store = EKEventStore()

    var access: RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestFullAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            // EventKit runs this on its own queue, not the main actor. A
            // closure written inside a @MainActor type is assumed to be
            // main-actor isolated, so Swift emits an executor check that
            // traps when the framework calls back elsewhere. @Sendable drops
            // that assumption. This crashed the moment the connector became
            // reachable - see saved-results/ios-demo-recording-blocked.md.
            self.store.requestFullAccessToReminders { @Sendable granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func incompleteReminders(limit: Int) async -> [Reminder] {
        // Read the store on the actor, then keep it out of the @Sendable
        // callback below - EKEventStore is not Sendable.
        let store = self.store
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let fetched: [Reminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { @Sendable reminders in
                // Mapped inside the callback so no EKReminder crosses out of
                // it; only the Sendable value type leaves.
                continuation.resume(returning: Self.map(reminders))
            }
        }
        // Soonest first, and anything with no due date after everything that
        // has one — an undated reminder is not urgent, it is unscheduled.
        return fetched
            .sorted { lhs, rhs in
                switch (lhs.due, rhs.due) {
                case let (l?, r?): l < r
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): lhs.title < rhs.title
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated private static func map(_ reminders: [EKReminder]?) -> [Reminder] {
        (reminders ?? []).map { reminder in
            Reminder(
                title: reminder.title ?? "",
                due: reminder.dueDateComponents.flatMap(Calendar.current.date(from:)),
                listName: reminder.calendar?.title ?? "")
        }
    }
}

#if canImport(UIKit)
extension ForegroundRemindersService {
    convenience init() {
        self.init(
            store: EventKitReminderStore(),
            isAppActive: { UIApplication.shared.applicationState == .active })
    }
}
#endif
