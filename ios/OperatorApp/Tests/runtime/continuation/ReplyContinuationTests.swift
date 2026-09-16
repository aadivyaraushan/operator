import Foundation
import XCTest
@testable import OperatorApp

@MainActor
final class ReplyContinuationTests: XCTestCase {
    private final class Scheduler: ContinuedProcessingScheduling {
        var handlers: [String: @MainActor (any ContinuedProcessingTask) -> Void] = [:]
        var submitted: [(identifier: String, title: String, subtitle: String)] = []
        var refuse = false
        struct Refused: Error {}
        func submit(identifier: String, title: String, subtitle: String, handler: @escaping @MainActor (any ContinuedProcessingTask) -> Void) throws {
            if self.refuse { throw Refused() }
            self.handlers[identifier] = handler
            self.submitted.append((identifier, title, subtitle))
        }
        /// The system starting the task it accepted.
        func start(_ identifier: String) -> FakeTask {
            let task = FakeTask(identifier: identifier)
            self.handlers[identifier]?(task)
            return task
        }
    }

    private final class FakeTask: ContinuedProcessingTask {
        let identifier: String
        var expirationHandler: (@Sendable () -> Void)?
        var progress: [Int] = []
        var subtitles: [String] = []
        var completed: [Bool] = []
        init(identifier: String) { self.identifier = identifier }
        func setProgress(completed: Int, total: Int) { self.progress.append(completed); XCTAssertEqual(total, 100) }
        func updateTitle(_ title: String, subtitle: String) { XCTAssertEqual(title, "Operator is working"); self.subtitles.append(subtitle) }
        func setTaskCompleted(success: Bool) { self.completed.append(success) }
    }

    func testOneTaskPerReplyFromSendToTheReplyWithProgressThatNeverGoesBackwards() {
        let scheduler = Scheduler()
        let continuation = ReplyContinuation(scheduler: scheduler)
        let id = UUID()
        XCTAssertTrue(continuation.begin(messageID: id, subtitle: "Thinking…"))
        XCTAssertTrue(continuation.isActive)
        XCTAssertEqual(scheduler.submitted.map(\.identifier), ["app.operator.ios.reply." + id.uuidString.lowercased()])
        XCTAssertFalse(continuation.begin(messageID: UUID(), subtitle: "again"), "one at a time")

        continuation.report(progress: 10, subtitle: "Thinking…")
        let task = scheduler.start(scheduler.submitted[0].identifier)
        XCTAssertEqual(task.progress, [10], "the system started the task late; it gets what was reported so far")
        XCTAssertEqual(task.subtitles, ["Thinking…"])
        continuation.report(progress: 40, subtitle: "Checking Discord announcements")
        continuation.report(progress: 30, subtitle: "Checking your calendar")
        XCTAssertEqual(task.progress, [10, 40, 40], "never backwards")
        XCTAssertEqual(task.subtitles.last, "Checking your calendar")

        continuation.finish(success: true)
        XCTAssertEqual(task.progress.last, 100)
        XCTAssertEqual(task.completed, [true])
        XCTAssertFalse(continuation.isActive)
        continuation.report(progress: 90, subtitle: "late")
        XCTAssertEqual(task.progress.count, 4, "nothing after the finish")
    }

    func testARefusedSubmissionLeavesTheReplyForegroundOnly() {
        let scheduler = Scheduler()
        scheduler.refuse = true
        let continuation = ReplyContinuation(scheduler: scheduler)
        XCTAssertFalse(continuation.begin(messageID: UUID(), subtitle: "Thinking…"))
        XCTAssertFalse(continuation.isActive)
        continuation.finish(success: true)
        XCTAssertFalse(continuation.isActive)
    }

    func testExpirationEndsTheTaskAndTellsTheAppAndAStrayTaskIsEndedAtOnce() {
        let scheduler = Scheduler()
        let continuation = ReplyContinuation(scheduler: scheduler)
        var expired = 0
        continuation.onExpired = { expired += 1 }
        let id = UUID()
        continuation.begin(messageID: id, subtitle: "Thinking…")
        let task = scheduler.start(scheduler.submitted[0].identifier)
        task.expirationHandler?()
        let done = expectation(description: "expiration reaches the main actor")
        Task { @MainActor in done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(task.completed, [false])
        XCTAssertFalse(continuation.isActive)
        XCTAssertEqual(expired, 1)

        // The system hands back the finished task's handler again later.
        let stray = scheduler.start(scheduler.submitted[0].identifier)
        XCTAssertEqual(stray.completed, [false], "a task for a message no longer tracked is ended, not driven")
        XCTAssertFalse(continuation.isActive)
    }
}
