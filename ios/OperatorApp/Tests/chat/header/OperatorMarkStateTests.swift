import XCTest
@testable import OperatorApp

/// Which of its three motions the header logo shows.
final class OperatorMarkStateTests: XCTestCase {
    func testNothingHappeningIsIdle() {
        XCTAssertEqual(OperatorMarkState(isWorking: false, needsPerson: false), .idle)
    }

    func testARunInProgressIsWorking() {
        XCTAssertEqual(OperatorMarkState(isWorking: true, needsPerson: false), .working)
    }

    func testAnOpenApprovalOrQuestionIsWaiting() {
        XCTAssertEqual(OperatorMarkState(isWorking: false, needsPerson: true), .waiting)
    }

    /// A run that has stopped to ask is still "working" to the runtime; the
    /// person needs to see that it is their move.
    func testWaitingWinsOverWorking() {
        XCTAssertEqual(OperatorMarkState(isWorking: true, needsPerson: true), .waiting)
    }
}
