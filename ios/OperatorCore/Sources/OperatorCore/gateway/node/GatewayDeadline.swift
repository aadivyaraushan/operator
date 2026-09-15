import Foundation

/// Bounding how long a node command may take.
///
/// The gateway hands every handler a `timeoutMilliseconds`, and most of them
/// were discarding it — which meant a caller had no way to bound a slow
/// connector, and a hung framework call or an unresponsive backend would wait
/// forever with nothing to say about it.
///
/// The clamp and the `TIMEOUT` failure code follow what
/// ForegroundWhatsAppComposeService already did, so every handler answers a
/// deadline the same way.
public enum GatewayDeadline {
    /// Used when the gateway supplies no deadline of its own.
    public static let defaultMilliseconds = 30_000
    /// A caller may ask for less than this, never more. A deadline a handler
    /// cannot be trusted to honour is not a deadline.
    public static let maximumMilliseconds = 30_000

    /// The deadline actually applied, given what the gateway asked for.
    public static func bounded(_ requested: Int?) -> Int {
        max(1, min(requested ?? Self.defaultMilliseconds, Self.maximumMilliseconds))
    }

    /// Runs `work` under a deadline, returning nil if the deadline passes
    /// first. The losing task is cancelled. A framework call that ignores
    /// cancellation may still finish later, but it cannot keep the caller
    /// waiting or replace the already-returned timeout result.
    public static func run<T: Sendable>(
        milliseconds: Int,
        _ work: @escaping @Sendable () async -> T) async -> T?
    {
        let race = DeadlineRace<T>()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                Task { await race.install(continuation) }

                let workTask = Task {
                    await race.resolve(await work())
                }
                Task { await race.setWorkTask(workTask) }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds)) * 1_000_000)
                    } catch {
                        return
                    }
                    await race.resolve(nil)
                }
                Task { await race.setTimeoutTask(timeoutTask) }
            }
        }, onCancel: {
            Task { await race.cancel() }
        })
    }
}

private actor DeadlineRace<T: Sendable> {
    private var finished = false
    private var result: T?
    private var continuation: CheckedContinuation<T?, Never>?
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        if self.finished {
            continuation.resume(returning: self.result)
        } else {
            self.continuation = continuation
        }
    }

    func setWorkTask(_ task: Task<Void, Never>) {
        guard !self.finished else {
            task.cancel()
            return
        }
        self.workTask = task
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        guard !self.finished else {
            task.cancel()
            return
        }
        self.timeoutTask = task
    }

    func resolve(_ result: T?) {
        guard !self.finished else { return }
        self.finished = true
        self.result = result
        self.continuation?.resume(returning: result)
        self.continuation = nil
        self.workTask?.cancel()
        self.timeoutTask?.cancel()
        self.workTask = nil
        self.timeoutTask = nil
    }

    func cancel() {
        self.resolve(nil)
    }
}
