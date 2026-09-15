import MessageUI
import OSLog
import UIKit

@MainActor
final class SystemMessageComposer: NSObject, MessageComposePresenter, @preconcurrency MFMessageComposeViewControllerDelegate {
    // Resolved on every call, never stored. This object is created inside
    // OperatorApp.init(), and on an iPhone 17 running iOS 26 a UIApplication
    // captured that early was not the one UIKit went on to run: it reported
    // applicationState .active (the zero default) with no delegate, no
    // sessions and no connected scenes, so sms.compose failed with
    // PRESENTATION_UNAVAILABLE in the foreground, every time. The launch-time
    // probe that found it is recorded in ios-connectors-evidence.md.
    private var application: UIApplication { .shared }
    private let logger = Logger(subsystem: "app.operator.ios", category: "message-compose")
    private var composer: MFMessageComposeViewController?

    var isAvailable: Bool {
        MFMessageComposeViewController.canSendText()
    }

    func present(recipients: [String], body: String) -> Bool {
        guard self.application.applicationState == .active, self.composer == nil else {
            self.logger.info("[message-compose] system composer presentation blocked active=\(self.application.applicationState == .active) busy=\(self.composer != nil)")
            return false
        }
        guard let host = ForegroundPresentationHost.topmost(in: self.application) else {
            self.logger.info("[message-compose] system composer presentation blocked: no host view controller")
            return false
        }

        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = self
        composer.recipients = recipients
        composer.body = body
        self.composer = composer
        host.present(composer, animated: true)
        self.logger.info("[message-compose] system composer presentation requested recipients=\(recipients.count)")
        return true
    }

    func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult)
    {
        let outcome: String
        switch result {
        case .sent: outcome = "sent"
        case .cancelled: outcome = "cancelled"
        case .failed: outcome = "failed"
        @unknown default: outcome = "unknown"
        }
        self.logger.info("[message-compose] system composer finished outcome=\(outcome, privacy: .public)")
        controller.dismiss(animated: true) { [weak self, weak controller] in
            guard let self, self.composer === controller else { return }
            self.composer = nil
        }
    }
}
