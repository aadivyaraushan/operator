#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// One handler per kind of actionable notification. The first that claims a
/// response handles it; the rest never see it.
protocol NotificationResponseHandling: Sendable {
    /// True when the response was this handler's to act on.
    func handle(_ response: UNNotificationResponse) async -> Bool
}

/// The notification center's one delegate, retained by the App for the life
/// of the process (the center holds it weakly). Unchecked only because
/// NSObject is not Sendable; every stored property is.
final class NotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let handlers: [any NotificationResponseHandling]

    init(handlers: [any NotificationResponseHandling]) {
        self.handlers = handlers
    }

    /// The system keeps the process running until this returns, which is
    /// what a send or an answer from a notification button needs.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        for handler in self.handlers where await handler.handle(response) { return }
    }

    /// A question or a report that lands while Operator is in front still
    /// shows; without this a foreground app's notifications are silent.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
#endif
