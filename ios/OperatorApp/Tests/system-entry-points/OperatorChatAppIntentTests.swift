import AppIntents
import XCTest
@testable import OperatorApp

final class OperatorChatAppIntentTests: XCTestCase {
    func testOpenOperatorIntentRequestsTheExistingAppWindow() {
        XCTAssertTrue(OperatorChatAppIntent.openAppWhenRun)
    }

    func testOpenOperatorShortcutRegistersOneAppIntent() {
        let shortcuts: [AppShortcut] = OperatorChatShortcuts.appShortcuts

        XCTAssertEqual(shortcuts.count, 1)
    }
}
