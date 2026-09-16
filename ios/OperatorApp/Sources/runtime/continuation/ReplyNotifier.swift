#if canImport(UserNotifications)
import Foundation
import OSLog
import UserNotifications

/// The reply as a local notification, for a reply that landed while the
/// person was elsewhere. Permission is asked once, in the foreground, so
/// the first background reply is not lost to an unanswered prompt.
@MainActor
enum ReplyNotifier {
    private static let logger = Logger(subsystem: "app.operator.ios", category: "reply-notifier")
    private static var requested = false

    static func requestPermissionIfNeeded() {
        guard !Self.requested else { return }
        Self.requested = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Self.logger.info("[reply-notifier] permission granted=\(granted)")
            }
        }
    }

    static func post(reply: String) {
        let content = UNMutableNotificationContent()
        content.title = "Operator"
        let flat = reply.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        content.body = flat.count > 240 ? String(flat.prefix(239)) + "…" : flat
        content.sound = .default
        let request = UNNotificationRequest(identifier: "reply-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("[reply-notifier] post failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            } else {
                Self.logger.info("[reply-notifier] posted characters=\(content.body.count)")
            }
        }
    }
}
#endif
