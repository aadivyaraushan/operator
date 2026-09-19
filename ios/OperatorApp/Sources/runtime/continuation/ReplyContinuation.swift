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
    private let heartbeatInterval: Duration
    private let logger = Logger(subsystem: "app.operator.ios", category: "reply-continuation")
    private var activeIdentifier: String?
    private var task: (any ContinuedProcessingTask)?
    private var heartbeat: Task<Void, Never>?
    private(set) var lastProgress = 0
    private(set) var lastSubtitle = ""
    /// The last value handed to the system; the heartbeat only ever raises it.
    private(set) var deliveredProgress = 0

    /// `heartbeatInterval`: how often the system task is told progress. It
    /// must hear something regularly or it expires the task (the phone log
    /// of 2026-09-16 10:37: "Task has not reported progress within expected
    /// cadence", then expiry, 32 seconds after a run with no reports).
    init(scheduler: any ContinuedProcessingScheduling, heartbeatInterval: Duration = .seconds(5)) {
        self.scheduler = scheduler
        self.heartbeatInterval = heartbeatInterval
    }

    /// Submits a task for this message. Returns false when the system
    /// refused, in which case the reply runs as it always has: foreground only.
    @discardableResult
    func begin(messageID: UUID, subtitle: String) -> Bool {
        guard !self.isActive else { return false }
        // Registration survives completion and even a refused submission for the
        // lifetime of this process. Recovery can retry the same message, so
        // each attempt needs a fresh identifier (duplicate registration aborts
        // inside BGTaskScheduler rather than throwing a Swift error).
        let identifier = Self.identifierPrefix + messageID.uuidString.lowercased() + "." + UUID().uuidString.lowercased()
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

    /// Records where the run is. Nothing reaches the system task here: the
    /// heartbeat delivers progress on its own cadence, in small monotone
    /// steps, so the system's card is not poked on every tool call and yet
    /// hears from the task often enough not to expire it. The title and
    /// subtitle are set at submission and never updated; a title change
    /// expands the card every time.
    func report(progress: Int, subtitle: String) {
        guard self.isActive else { return }
        self.lastProgress = max(self.lastProgress, min(progress, Self.progressTotal))
        self.lastSubtitle = subtitle
    }

    func finish(success: Bool) {
        guard self.isActive else { return }
        if success { self.task?.setProgress(completed: Self.progressTotal, total: Self.progressTotal) }
        self.task?.setTaskCompleted(success: success)
        self.logger.info("[reply-continuation] finished success=\(success)")
        self.clear()
    }

    /// One tick: the greater of what the run reported and one step past the
    /// last delivery, never above 95 until the finish. A change every tick
    /// is what keeps the scheduler's progress tracker healthy.
    private func tick() {
        guard let task else { return }
        let next = min(max(self.lastProgress, self.deliveredProgress + 1), Self.progressTotal - 5)
        guard next > self.deliveredProgress else { return }
        self.deliveredProgress = next
        task.setProgress(completed: next, total: Self.progressTotal)
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
        self.tick()
        self.heartbeat = Task { @MainActor [weak self, interval = self.heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
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
        self.heartbeat?.cancel()
        self.heartbeat = nil
        self.task = nil
        self.activeIdentifier = nil
        self.isActive = false
        self.deliveredProgress = 0
    }
}
