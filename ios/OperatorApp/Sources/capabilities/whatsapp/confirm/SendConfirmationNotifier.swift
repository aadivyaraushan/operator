#if canImport(UserNotifications)
import Foundation
import OSLog
import UserNotifications

/// The question as a notification: "Send to Villa on WhatsApp?" with the
/// draft as the body and two buttons, Send (the phone must be unlocked) and
/// Don't send. The answer comes back through `SendConfirmationResponder`.
@MainActor
final class SendConfirmationNotifier: SendConfirmationNotifying {
    nonisolated static let category = "confirm-send"
    nonisolated static let sendAction = "send"
    nonisolated static let declineAction = "decline"
    nonisolated static let idKey = "pendingSendID"
    private static let prefix = "confirm-send-"
    private static let thread = "whatsapp-send"
    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "app.operator.ios", category: "send-confirmation")

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    /// Once, at launch, before any question can be posted: a notification
    /// whose category is not registered shows no buttons at all.
    func registerCategory() {
        let send = UNNotificationAction(identifier: Self.sendAction, title: "Send", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Don't send", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.category, actions: [send, decline], intentIdentifiers: [], options: [])
        self.center.setNotificationCategories([category])
    }

    /// The draft the answered notification was about, if it was a question.
    nonisolated static func pendingSendID(in response: UNNotificationResponse) -> String? {
        let content = response.notification.request.content
        guard content.categoryIdentifier == Self.category else { return nil }
        return content.userInfo[Self.idKey] as? String
    }

    func askToConfirm(id: String, recipientName: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Send to \(recipientName) on WhatsApp?"
        content.body = Self.bounded(body)
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = Self.thread
        content.userInfo = [Self.idKey: id]
        self.post(UNNotificationRequest(identifier: Self.prefix + id, content: content, trigger: nil), what: "question")
    }

    func withdraw(id: String) {
        self.center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + id])
        self.center.removePendingNotificationRequests(withIdentifiers: [Self.prefix + id])
    }

    func report(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = Self.bounded(body)
        content.sound = .default
        content.threadIdentifier = Self.thread
        self.post(UNNotificationRequest(identifier: "send-report-\(UUID().uuidString)", content: content, trigger: nil), what: "report")
    }

    private func post(_ request: UNNotificationRequest, what: String) {
        self.center.add(request) { [logger] error in
            if let error {
                logger.error("[send-confirmation] \(what, privacy: .public) failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            } else {
                logger.info("[send-confirmation] \(what, privacy: .public) posted")
            }
        }
    }

    private static func bounded(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 240 ? String(flat.prefix(239)) + "…" : flat
    }
}

/// Answers to the question: the notification's buttons, or a tap on the
/// notification itself. Retained by the App for the life of the process; the
/// notification center only holds its delegate weakly. Unchecked only
/// because NSObject is not Sendable: every stored property is.
final class SendConfirmationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: PendingSendCenter
    private let presenter: any WhatsAppComposePresenter
    private let isOnScreen: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "send-confirmation")

    @MainActor
    init(center: PendingSendCenter, presenter: any WhatsAppComposePresenter, isOnScreen: @escaping @MainActor @Sendable () -> Bool) {
        self.center = center
        self.presenter = presenter
        self.isOnScreen = isOnScreen
    }

    /// The system keeps the process running until this returns, which is
    /// what a send from the Send button needs.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = SendConfirmationNotifier.pendingSendID(in: response) else { return }
        await self.answer(response.actionIdentifier, id: id)
    }

    /// A question or a report that lands while Operator is in front still
    /// shows; without this a foreground app's notifications are silent.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    @MainActor
    private func answer(_ action: String, id: String) async {
        switch action {
        case SendConfirmationNotifier.sendAction:
            self.logger.info("[send-confirmation] answered send")
            _ = await self.center.perform(id: id)
        case SendConfirmationNotifier.declineAction:
            self.logger.info("[send-confirmation] answered decline")
            self.center.decline(id: id)
        case UNNotificationDefaultActionIdentifier:
            // The app is coming to the front; the alert needs it there.
            self.logger.info("[send-confirmation] answered open")
            await self.waitUntilOnScreen()
            _ = await self.center.confirmOnScreen(id: id, presenter: self.presenter)
        default:
            // Dismissed: the draft stays until it expires or is replaced.
            self.logger.info("[send-confirmation] dismissed")
        }
    }

    @MainActor
    private func waitUntilOnScreen() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !self.isOnScreen(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
