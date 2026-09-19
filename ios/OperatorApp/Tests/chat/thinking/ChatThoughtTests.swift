import XCTest
@testable import OperatorApp

/// The "Thought for 6s" line kept above a reply.
final class ChatThoughtTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testSecondsAreRoundedIntoTheLabel() throws {
        let thought = try XCTUnwrap(ChatThought(from: self.start, to: self.start.addingTimeInterval(5.6), activity: nil))
        XCTAssertEqual(thought.label, "Thought for 6s")
    }

    func testAMinuteOrMoreReadsInMinutes() {
        XCTAssertEqual(ChatThought.label(seconds: 65), "Thought for 1m 5s")
    }

    func testUnderASecondIsNotWorthALine() {
        XCTAssertNil(ChatThought(from: self.start, to: self.start.addingTimeInterval(0.3), activity: nil))
    }

    func testItKeepsWhatWasThought() throws {
        var activity = ChatLiveActivity()
        activity.apply(.commentary(text: "Checking the calendar first"))
        activity.apply(.thinking(text: "The dentist is at 14:00"))
        let thought = try XCTUnwrap(ChatThought(from: self.start, to: self.start.addingTimeInterval(3), activity: activity))
        XCTAssertTrue(thought.hasText)
        XCTAssertEqual(thought.commentary, ["Checking the calendar first"])
        XCTAssertEqual(thought.reasoning, "The dentist is at 14:00")
    }
}
