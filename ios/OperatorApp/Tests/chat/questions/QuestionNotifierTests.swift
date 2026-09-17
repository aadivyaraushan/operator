import Foundation
import OperatorCore
import UserNotifications
import XCTest
@testable import OperatorApp

/// The shape of a question's notification: which questions get buttons,
/// what the buttons are, and what a response means.
final class QuestionNotifierTests: XCTestCase {
    private func record(_ questions: [GatewayQuestion]) -> GatewayQuestionRecord {
        GatewayQuestionRecord(id: "ask_1", questions: questions, sessionKey: "agent:main:main", runID: "run",
                              createdAtMilliseconds: 1, expiresAtMilliseconds: 9_999_999_999_999)
    }

    private func single(_ options: [String], multiSelect: Bool = false, isOther: Bool = false) -> GatewayQuestion {
        GatewayQuestion(questionId: "group_message", header: "Message", question: "What should I send?",
                        options: options.map { .init(label: $0) }, multiSelect: multiSelect, isOther: isOther)
    }

    func testASingleChoiceQuestionsOptionsAreTheButtonsPlusSkip() {
        let actions = QuestionNotifier.actions(for: self.record([self.single(["MVP update", "Call now", "Meet tomorrow"])]))
        XCTAssertEqual(actions.map(\.identifier), ["option-0", "option-1", "option-2", "skip"])
        XCTAssertEqual(actions.map(\.title), ["MVP update", "Call now", "Meet tomorrow", "Skip"])
        XCTAssertFalse(actions.contains { $0 is UNTextInputNotificationAction })
    }

    func testFourOptionsLeaveNoRoomForSkipOrTyping() {
        let actions = QuestionNotifier.actions(for: self.record([self.single(["a", "b", "c", "d"], isOther: true)]))
        XCTAssertEqual(actions.map(\.identifier), ["option-0", "option-1", "option-2", "option-3"])
    }

    func testAFreeTextQuestionGetsATextFieldAndSkip() {
        let actions = QuestionNotifier.actions(for: self.record([self.single([])]))
        XCTAssertEqual(actions.map(\.identifier), ["typed", "skip"])
        XCTAssertTrue(actions.first is UNTextInputNotificationAction)
        XCTAssertEqual(actions.first?.title, "Answer")
    }

    func testOptionsWithOtherGetButtonsThenATextField() {
        let actions = QuestionNotifier.actions(for: self.record([self.single(["Call now", "Meet tomorrow"], isOther: true)]))
        XCTAssertEqual(actions.map(\.identifier), ["option-0", "option-1", "typed", "skip"])
        XCTAssertEqual(actions[2].title, "Type your own")
    }

    func testMultiSelectAndMultiQuestionRecordsHaveNoButtonsAndSayToOpenOperator() {
        let multi = self.record([self.single(["a", "b"], multiSelect: true)])
        let several = self.record([self.single(["a", "b"]), GatewayQuestion(questionId: "when", header: "When", question: "When?", options: [])])
        XCTAssertTrue(QuestionNotifier.actions(for: multi).isEmpty)
        XCTAssertTrue(QuestionNotifier.actions(for: several).isEmpty)
        XCTAssertEqual(QuestionNotifier.body(for: several, hasActions: false), "What should I send? When? Open Operator to answer.")
        XCTAssertEqual(QuestionNotifier.body(for: multi, hasActions: true), "What should I send?")
    }

    func testTheBodyStaysWithinANotificationsRoom() {
        let long = self.record([GatewayQuestion(questionId: "q", header: "", question: String(repeating: "x", count: 400), options: [])])
        let body = QuestionNotifier.body(for: long, hasActions: false)
        XCTAssertLessThanOrEqual(body.count, 240)
        XCTAssertTrue(body.hasSuffix("… Open Operator to answer."))
    }
}
