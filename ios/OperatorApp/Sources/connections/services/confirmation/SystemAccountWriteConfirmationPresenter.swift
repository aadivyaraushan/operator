#if canImport(UIKit)
import UIKit

@MainActor final class SystemAccountWriteConfirmationPresenter: AccountWriteConfirmationPresenting {
    private weak var alert: UIAlertController?
    private var continuation: CheckedContinuation<AccountWriteDecision, Never>?
    private var generation = 0

    func confirm(_ request: AccountWriteConfirmationRequest) async -> AccountWriteDecision {
        cancel(); generation += 1; let run = generation
        guard let host = Self.host() else { return .denied }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let alert = UIAlertController(title: "Allow account action?", message: request.preview, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(.denied, run: run) })
            alert.addAction(UIAlertAction(title: "Allow", style: .default) { [weak self] _ in self?.finish(.confirmed(request), run: run) })
            self.alert = alert; host.present(alert, animated: true)
        }
    }

    func cancel() { generation += 1; alert?.dismiss(animated: true); let saved = continuation; continuation = nil; alert = nil; saved?.resume(returning: .denied) }
    private func finish(_ value: AccountWriteDecision, run: Int) { guard generation == run else { return }; let saved = continuation; continuation = nil; alert = nil; saved?.resume(returning: value) }
    private static func host() -> UIViewController? { ForegroundPresentationHost.topmost() }
}
#endif
