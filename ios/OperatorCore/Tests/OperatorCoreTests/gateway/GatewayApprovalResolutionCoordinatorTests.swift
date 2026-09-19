import XCTest
@testable import OperatorCore

final class GatewayApprovalResolutionCoordinatorTests: XCTestCase {
    func testEarlyResolutionIsConsumedOnceAndDuplicateTerminalsDoNotLeaveRememberedIDs() {
        var coordinator = GatewayApprovalResolutionCoordinator()

        coordinator.notePending(id: "approval-exact-1")
        XCTAssertFalse(coordinator.recordResolution(id: "approval-exact-1"))
        XCTAssertEqual(coordinator.rememberedResolutionCount, 1)

        XCTAssertFalse(coordinator.beginWaiting(id: "approval-exact-1"))
        XCTAssertEqual(coordinator.rememberedResolutionCount, 0)

        XCTAssertFalse(coordinator.recordResolution(id: "approval-exact-1"))
        XCTAssertEqual(coordinator.rememberedResolutionCount, 0)
    }

    func testResolutionForInstalledWaiterResumesOnce() {
        var coordinator = GatewayApprovalResolutionCoordinator()

        coordinator.notePending(id: "approval-exact-2")
        XCTAssertTrue(coordinator.beginWaiting(id: "approval-exact-2"))
        XCTAssertTrue(coordinator.recordResolution(id: "approval-exact-2"))
        XCTAssertFalse(coordinator.recordResolution(id: "approval-exact-2"))
        XCTAssertEqual(coordinator.rememberedResolutionCount, 0)
    }

    func testEarlyResolutionsStayBoundedWhenNoWaiterIsInstalled() {
        var coordinator = GatewayApprovalResolutionCoordinator()

        for index in 0 ... 64 {
            let id = "approval-\(index)"
            coordinator.notePending(id: id)
            XCTAssertFalse(coordinator.recordResolution(id: id))
        }

        XCTAssertEqual(coordinator.rememberedResolutionCount, 64)
    }
}
