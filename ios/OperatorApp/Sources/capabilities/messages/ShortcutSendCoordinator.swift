import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Runs the send shortcut and waits for it to come back, so the model learns
/// what happened and its turn can continue after the send instead of ending
/// the moment Operator hands off.
///
/// The shortcut runs in the Shortcuts app, so opening it backgrounds Operator.
/// Two things keep the run alive across that hop: a background-task assertion
/// so iOS does not suspend the process for the few seconds Shortcuts needs,
/// and `isSending`, which the app lifecycle reads so the runtime and the node
/// route are not torn down while a send is out. When Shortcuts returns to
/// `app.operator.ios://shortcut/*`, the app resolves the wait with the
/// outcome; if it never returns, a timeout ends the wait as `timedOut`.
@MainActor
final class ShortcutSendCoordinator: ObservableObject {
    enum Outcome: String, Sendable {
        case success, error, cancel, timedOut, couldNotOpen
    }

    /// True from the moment the shortcut is opened until it comes back or the
    /// wait times out. The app keeps the runtime alive while this holds.
    @Published private(set) var isSending = false

    private let runner: any ShortcutRunner
    private let timeout: Duration
    private let logger = Logger(subsystem: "app.operator.ios", category: "message-send")
    private var pending: CheckedContinuation<Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(runner: any ShortcutRunner, timeout: Duration = .seconds(180)) {
        self.runner = runner
        self.timeout = timeout
    }

    /// Opens the shortcut and waits for its callback. Returns `couldNotOpen`
    /// when the URL will not open (no shortcut), without ever waiting.
    func send(_ url: URL) async -> Outcome {
        guard self.pending == nil else {
            // One send at a time; the guard (20 s apart) makes overlap rare,
            // and a second send while one is out is treated as unopenable
            // rather than silently jumping the first.
            self.logger.info("[message-send] a send is already awaiting its callback")
            return .couldNotOpen
        }
        self.isSending = true
        self.beginBackgroundTask()
        guard await self.runner.run(url) else {
            self.isSending = false
            self.endBackgroundTask()
            return .couldNotOpen
        }
        self.logger.info("[message-send] shortcut opened; awaiting callback")
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            self.pending = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: self?.timeout ?? .seconds(180))
                self?.resolve(.timedOut)
            }
        }
        self.isSending = false
        self.endBackgroundTask()
        self.logger.info("[message-send] callback outcome=\(outcome.rawValue, privacy: .public)")
        return outcome
    }

    /// Delivered by the app when Shortcuts returns to Operator's scheme.
    func resolve(_ outcome: Outcome) {
        guard let pending = self.pending else { return }
        self.pending = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        pending.resume(returning: outcome)
    }

    private func beginBackgroundTask() {
        #if canImport(UIKit)
        guard self.backgroundTask == .invalid else { return }
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "operator-shortcut-send") { [weak self] in
            // iOS is about to reclaim the assertion; end the wait so the run
            // is not left hanging. The callback, if it lands after the app
            // resumes, then finds nothing pending and is simply logged.
            self?.resolve(.timedOut)
        }
        #endif
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        guard self.backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.backgroundTask)
        self.backgroundTask = .invalid
        #endif
    }
}
