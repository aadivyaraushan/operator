import Foundation
import OSLog

/// What the app needs from the system's continued-processing scheduler, so
/// the lifecycle can be tested without BackgroundTasks. `submit` runs while
/// the app is in front and registers the handler for that exact identifier
/// first: the wildcard in Info.plist only permits the family, and a
/// submission whose own identifier has no handler is an uncaught exception
/// (the phone log of 2026-09-16 01:22:44). The scheduler later calls the
/// handler with a running task, which the app drives to completion.
@MainActor
protocol ContinuedProcessingScheduling: AnyObject {
    /// Throws when the handler cannot be registered or the system will not
    /// run the task now.
    func submit(identifier: String, title: String, subtitle: String, handler: @escaping @MainActor (any ContinuedProcessingTask) -> Void) throws
}

/// Not main-actor bound: the system hands it over on its own queue and the
/// underlying BGTask is safe from any thread. ReplyContinuation drives it
/// from the main actor.
protocol ContinuedProcessingTask: AnyObject, Sendable {
    var identifier: String { get }
    /// Called by the system when the task must stop.
    var expirationHandler: (@Sendable () -> Void)? { get set }
    func setProgress(completed: Int, total: Int)
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

/// Keeps one reply alive after the person leaves the app: a task per
/// message, begun on send, reported as the run proceeds, finished with the
/// reply. `isActive` is what the app's foreground gate consults.
@MainActor
final class ReplyContinuation: ObservableObject {
    static let identifierPrefix = "app.operator.ios.reply."
    static let wildcardIdentifier = identifierPrefix + "*"
    static let title = "Operator is working"
    static let progressTotal = 100

    /// True from a successful submission until the task finishes or
    /// expires, whether or not the system has started it yet.
    @Published private(set) var isActive = false
    /// Set when the system ended the task before the reply: the app must
    /// then apply the background transition it deferred.
    var onExpired: (@MainActor () -> Void)?

    private let scheduler: any ContinuedProcessingScheduling
    private let logger = Logger(subsystem: "app.operator.ios", category: "reply-continuation")
    private var activeIdentifier: String?
    private var task: (any ContinuedProcessingTask)?
    private(set) var lastProgress = 0
    private(set) var lastSubtitle = ""

    init(scheduler: any ContinuedProcessingScheduling) {
        self.scheduler = scheduler
    }

    /// Submits a task for this message. Returns false when the system
    /// refused, in which case the reply runs as it always has: foreground only.
    @discardableResult
    func begin(messageID: UUID, subtitle: String) -> Bool {
        guard !self.isActive else { return false }
        let identifier = Self.identifierPrefix + messageID.uuidString.lowercased()
        do {
            try self.scheduler.submit(identifier: identifier, title: Self.title, subtitle: subtitle) { [weak self] task in
                self?.attach(task)
            }
        } catch {
            self.logger.info("[reply-continuation] refused errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return false
        }
        self.activeIdentifier = identifier
        self.isActive = true
        self.lastProgress = 0
        self.lastSubtitle = subtitle
        self.logger.info("[reply-continuation] submitted")
        return true
    }

    /// Records where the run is; nothing reaches the system's Live Activity
    /// mid-run. Title updates expanded the full card on every step, and on
    /// the phone progress updates did too, so the task is told nothing
    /// between submission and completion: the owner wants the small pill in
    /// the Dynamic Island and a notification at the end, nothing in between.
    /// Progress is still tracked here for the log and for tests.
    func report(progress: Int, subtitle: String) {
        guard self.isActive else { return }
        self.lastProgress = max(self.lastProgress, min(progress, Self.progressTotal))
        self.lastSubtitle = subtitle
    }

    func finish(success: Bool) {
        guard self.isActive else { return }
        self.task?.setTaskCompleted(success: success)
        self.logger.info("[reply-continuation] finished success=\(success)")
        self.clear()
    }

    private func attach(_ task: any ContinuedProcessingTask) {
        guard task.identifier == self.activeIdentifier else {
            // A task the system started for a message this launch no longer
            // tracks (or a stale identifier): end it at once.
            task.setTaskCompleted(success: false)
            return
        }
        self.task = task
        let identifier = task.identifier
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(identifier) }
        }
        self.logger.info("[reply-continuation] running")
    }

    private func expire(_ identifier: String) {
        guard identifier == self.activeIdentifier else { return }
        self.logger.info("[reply-continuation] expired")
        self.task?.setTaskCompleted(success: false)
        self.clear()
        self.onExpired?()
    }

    private func clear() {
        self.task = nil
        self.activeIdentifier = nil
        self.isActive = false
    }
}
