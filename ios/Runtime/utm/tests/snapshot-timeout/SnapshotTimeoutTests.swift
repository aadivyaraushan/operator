import XCTest
@testable import QEMUKit
import QEMUKitInternal

final class SnapshotTimeoutTests: XCTestCase {
    func testSnapshotDeadlineAllowsDelayedSuccess() async throws {
        let port = DelayedResponsePort(delay: 11)
        let monitor = QEMUMonitor(port: port)

        let result = try await monitor.qemuSaveSnapshot("suspend")
        XCTAssertEqual(result, "")
    }

    func testRestoreDeadlineAllowsDelayedSuccess() async throws {
        let port = DelayedResponsePort(delay: 11)
        let monitor = QEMUMonitor(port: port)

        let result = try await monitor.qemuRestoreSnapshot("suspend")
        XCTAssertEqual(result, "")
    }

    func testOrdinaryCommandStillTimesOutAfterTenSeconds() async {
        let port = DelayedResponsePort(delay: 11)
        let monitor = QEMUMonitor(port: port)
        // Reuse the same monitor: the snapshot deadline must not leak to Stop.
        do {
            let result = try await monitor.qemuSaveSnapshot("suspend")
            XCTAssertEqual(result, "")
        } catch {
            XCTFail("snapshot setup failed: \(error)")
            return
        }
        let started = Date()

        do {
            try await monitor.qemuStop()
            XCTFail("ordinary command unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Timed out waiting for RPC.")
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 9.5)
        XCTAssertLessThan(elapsed, 11)
    }
}

private final class DelayedResponsePort: NSObject, QEMUPort {
    var readDataHandler: ((Data) -> Void)?
    var errorHandler: ((String) -> Void)?
    var disconnectHandler: (() -> Void)?
    let isOpen = true
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func write(_ data: Data) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.readDataHandler?(Data("{\"return\":\"\"}".utf8))
        }
    }
}
