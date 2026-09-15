#if canImport(UIKit)
import UIKit

@MainActor final class SystemWhatsAppComposePresenter: NSObject, WhatsAppComposePresenter {
    private weak var alert: UIAlertController?; private var continuation: CheckedContinuation<WhatsAppComposeDecision, Never>?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func confirm(_ request: WhatsAppComposeRequest) async -> WhatsAppComposeDecision {
        guard alert == nil, let host = Self.hostViewController() else { return .denied }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let alert = UIAlertController(title: "Send WhatsApp message?", message: "To: \(request.recipientJID)\n\n\(request.body)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(.denied) })
            alert.addAction(UIAlertAction(title: "Send", style: .default) { [weak self] _ in self?.finish(.confirmed(request)) })
            self.alert = alert; host.present(alert, animated: true)
        }
    }
    func cancel() { alert?.dismiss(animated: true); finish(.denied) }
    @objc private func didEnterBackground() { cancel() }
    private func finish(_ decision: WhatsAppComposeDecision) { alert = nil; let saved = continuation; continuation = nil; saved?.resume(returning: decision) }
    private static func hostViewController() -> UIViewController? { ForegroundPresentationHost.topmost() }
}
#endif
