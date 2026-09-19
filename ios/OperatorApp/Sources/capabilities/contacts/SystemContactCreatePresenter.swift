#if canImport(UIKit)
import UIKit

/// The system alert that stands between the agent and the address book:
/// name and every handle shown, Cancel or Save.
@MainActor final class SystemContactCreatePresenter: NSObject, ContactCreatePresenter {
    private weak var alert: UIAlertController?
    private var continuation: CheckedContinuation<ContactCreateDecision, Never>?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(self.didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func confirm(_ draft: ContactDraft) async -> ContactCreateDecision {
        guard self.alert == nil, let host = ForegroundPresentationHost.topmost() else { return .denied }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let lines = [draft.displayName] + draft.phoneNumbers + draft.emailAddresses
            let alert = UIAlertController(title: "Save new contact?", message: lines.joined(separator: "\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(.denied) })
            alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in self?.finish(.confirmed(draft)) })
            self.alert = alert
            host.present(alert, animated: true)
        }
    }

    func cancel() {
        self.alert?.dismiss(animated: true)
        self.finish(.denied)
    }

    @objc private func didEnterBackground() { self.cancel() }

    private func finish(_ decision: ContactCreateDecision) {
        self.alert = nil
        let saved = self.continuation
        self.continuation = nil
        saved?.resume(returning: decision)
    }
}
#endif
