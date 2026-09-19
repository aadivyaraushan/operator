#if canImport(BackgroundTasks) && os(iOS) && compiler(>=6.2)
import BackgroundTasks
import Foundation

/// BackgroundTasks behind the protocol. Registration for a continued
/// processing identifier is allowed after launch; submission must happen
/// while the app is in front. On iOS 18 and 25 there is no such task:
/// every submission is refused and the reply stays foreground-only.
@MainActor
final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    struct Unavailable: Error {}
    struct NotRegistered: Error {}

    func submit(identifier: String, title: String, subtitle: String, handler: @escaping @MainActor (any ContinuedProcessingTask) -> Void) throws {
        guard #available(iOS 26.0, *) else { throw Unavailable() }
        // The handler must exist for this exact identifier before the
        // request is submitted; submitting without one is fatal, not an error.
        // The scheduler calls it on its own queue: the closure must not
        // inherit this class's main-actor isolation, or the runtime traps
        // (crash of 2026-09-16 01:30:31, dispatch_assert_queue in the launch
        // handler). Everything main-actor happens inside the hop.
        let launch: @Sendable (BGTask) -> Void = { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let wrapped = SystemContinuedProcessingTask(continued)
            Task { @MainActor in handler(wrapped) }
        }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: launch)
        guard registered else { throw NotRegistered() }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }
}

/// Created on the scheduler's queue and used from the main actor. BGTask
/// and NSProgress are safe to call from any thread, which is what the
/// unchecked conformance states.
@available(iOS 26.0, *)
private final class SystemContinuedProcessingTask: ContinuedProcessingTask, @unchecked Sendable {
    private let task: BGContinuedProcessingTask
    init(_ task: BGContinuedProcessingTask) { self.task = task }
    var identifier: String { self.task.identifier }
    var expirationHandler: (@Sendable () -> Void)? {
        get { self.task.expirationHandler }
        set { self.task.expirationHandler = newValue }
    }
    func setProgress(completed: Int, total: Int) {
        self.task.progress.totalUnitCount = Int64(total)
        self.task.progress.completedUnitCount = Int64(completed)
    }
    func updateTitle(_ title: String, subtitle: String) { self.task.updateTitle(title, subtitle: subtitle) }
    func setTaskCompleted(success: Bool) { self.task.setTaskCompleted(success: success) }
}
#else
import Foundation

/// SDKs before iOS 26 (Swift 6.1 and older) have no continued processing
/// task type, so this build cannot reference it. Every submission is
/// refused and the reply stays foreground-only, the same as iOS 18 at runtime.
@MainActor
final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    struct Unavailable: Error {}

    func submit(identifier: String, title: String, subtitle: String, handler: @escaping @MainActor (any ContinuedProcessingTask) -> Void) throws {
        throw Unavailable()
    }
}
#endif
