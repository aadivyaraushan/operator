import XCTest
@testable import OperatorCore

final class RuntimeLifecycleMachineTests: XCTestCase {
    func testColdLaunchStartsAndBackgroundSnapshotsThenForegroundRestores() {
        var machine = RuntimeLifecycleMachine()

        XCTAssertEqual(machine.handle(.becameActive), [.start])
        XCTAssertEqual(machine.state, .starting)
        XCTAssertEqual(machine.handle(.started), [])
        XCTAssertEqual(machine.state, .ready)
        XCTAssertEqual(machine.handle(.enteredBackground), [.prepareGatewaySuspend, .saveSnapshot])
        XCTAssertEqual(machine.state, .suspending)
        XCTAssertEqual(machine.handle(.snapshotSaved), [])
        XCTAssertEqual(machine.state, .suspended)
        XCTAssertEqual(machine.handle(.becameActive), [.restoreSnapshot])
        XCTAssertEqual(machine.state, .starting)
    }

    func testRepeatedLifecycleNotificationsDoNotStartOrSnapshotTwice() {
        var machine = RuntimeLifecycleMachine()

        XCTAssertEqual(machine.handle(.becameActive), [.start])
        XCTAssertEqual(machine.handle(.becameActive), [])
        _ = machine.handle(.started)
        XCTAssertEqual(machine.handle(.enteredBackground), [.prepareGatewaySuspend, .saveSnapshot])
        XCTAssertEqual(machine.handle(.enteredBackground), [])
    }

    func testFailedRuntimeCanRetryOnNextForeground() {
        var machine = RuntimeLifecycleMachine()
        _ = machine.handle(.becameActive)
        XCTAssertEqual(machine.handle(.failed("boot failed")), [])
        XCTAssertEqual(machine.state, .failed("boot failed"))
        XCTAssertEqual(machine.handle(.becameActive), [.start])
    }
}
