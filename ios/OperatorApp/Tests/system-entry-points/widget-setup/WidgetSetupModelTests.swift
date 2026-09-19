import XCTest
@testable import OperatorApp

@MainActor
final class WidgetSetupModelTests: XCTestCase {
    private final class Store: WidgetSetupStore {
        var finished = false
        func loadFinished() -> Bool { self.finished }
        func saveFinished() { self.finished = true }
    }

    private final class Placement: WidgetPlacementChecking, @unchecked Sendable {
        var placed: Bool
        init(placed: Bool) { self.placed = placed }
        func isOperatorWidgetPlaced() async -> Bool { self.placed }
    }

    func testStepIsDueOnAFreshInstallWithNoWidget() async {
        let model = WidgetSetupModel(store: Store(), placement: Placement(placed: false))
        await model.refresh()
        XCTAssertTrue(model.isDue)
        XCTAssertFalse(model.isPlaced)
    }

    func testStepIsNotDueBeforeTheFirstCheckReturns() {
        let model = WidgetSetupModel(store: Store(), placement: Placement(placed: false))
        XCTAssertFalse(model.isDue)
    }

    func testStepIsSkippedForGoodWhenTheWidgetIsAlreadyThere() async {
        let store = Store()
        let model = WidgetSetupModel(store: store, placement: Placement(placed: true))
        await model.refresh()
        XCTAssertFalse(model.isDue)
        XCTAssertTrue(store.finished)
    }

    func testStepStaysUpAndShowsAddedWhenTheWidgetAppearsWhileItIsShowing() async {
        let store = Store()
        let placement = Placement(placed: false)
        let model = WidgetSetupModel(store: store, placement: placement)
        await model.refresh()
        placement.placed = true
        await model.refresh()
        XCTAssertTrue(model.isDue)
        XCTAssertTrue(model.isPlaced)
        XCTAssertFalse(store.finished)
    }

    func testFinishingClosesTheStepAndItNeverComesBack() async {
        let store = Store()
        let model = WidgetSetupModel(store: store, placement: Placement(placed: false))
        await model.refresh()
        model.finish()
        XCTAssertFalse(model.isDue)
        XCTAssertTrue(store.finished)

        let relaunched = WidgetSetupModel(store: store, placement: Placement(placed: false))
        await relaunched.refresh()
        XCTAssertFalse(relaunched.isDue)
    }

    func testFirstRunShowsPermissionsThenTheWidgetStepThenNothing() {
        XCTAssertEqual(FirstRunStep(permissionsDone: false, widgetStepDue: true), .permissions)
        XCTAssertEqual(FirstRunStep(permissionsDone: true, widgetStepDue: true), .widget)
        XCTAssertNil(FirstRunStep(permissionsDone: true, widgetStepDue: false))
    }
}
