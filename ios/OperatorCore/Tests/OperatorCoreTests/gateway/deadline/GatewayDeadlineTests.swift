import XCTest
@testable import OperatorCore

final class GatewayDeadlineTests: XCTestCase {
    func testReturnsCompletedWorkResult() async {
        let result = await GatewayDeadline.run(milliseconds: 500) { 42 }

        XCTAssertEqual(result, 42)
    }

    func testPreservesAnOptionalWorkResult() async {
        let result: Int?? = await GatewayDeadline.run(milliseconds: 500) { Optional<Int>.none }

        XCTAssertNotNil(result as Any?)
        XCTAssertNil(result!)
    }

    func testReturnsNilAtDeadlineBeforeNonCooperativeWorkCompletesAndIgnoresLateResult() async {
        let gate = NonCooperativeGate()
        let completion = DeadlineCompletion()
        let call = Task {
            let result = await GatewayDeadline.run(milliseconds: 20) {
                await gate.waitForRelease()
                return 42
            }
            await completion.record(result)
        }

        await gate.waitUntilStarted()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let timedOut = await completion.snapshot()
        XCTAssertTrue(timedOut.finished, "deadline should return without waiting for non-cooperative work")
        XCTAssertNil(timedOut.result)

        await gate.release()
        await call.value

        let afterLateResult = await completion.snapshot()
        XCTAssertEqual(afterLateResult.count, 1)
        XCTAssertNil(afterLateResult.result, "a result arriving after the deadline must not replace timeout")
    }

    func testOuterCancellationReturnsWithoutWaitingForNonCooperativeWork() async {
        let gate = NonCooperativeGate()
        let completion = DeadlineCompletion()
        let call = Task {
            let result = await GatewayDeadline.run(milliseconds: 1_000) {
                await gate.waitForRelease()
                return 42
            }
            await completion.record(result)
        }

        await gate.waitUntilStarted()
        call.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let cancelled = await completion.snapshot()
        XCTAssertTrue(cancelled.finished, "cancelling the caller should not wait for non-cooperative work")
        XCTAssertNil(cancelled.result)

        await gate.release()
        await call.value
    }
}

private actor NonCooperativeGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            self.started = true
            self.startWaiter?.resume()
            self.startWaiter = nil
            if self.released {
                continuation.resume()
            } else {
                self.releaseWaiter = continuation
            }
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { self.startWaiter = $0 }
    }

    func release() {
        self.released = true
        self.releaseWaiter?.resume()
        self.releaseWaiter = nil
    }
}

private actor DeadlineCompletion {
    private var values: [Int?] = []

    func record(_ value: Int?) {
        self.values.append(value)
    }

    func snapshot() -> (finished: Bool, result: Int?, count: Int) {
        (finished: !self.values.isEmpty, result: self.values.first ?? nil, count: self.values.count)
    }
}
