import XCTest
@testable import OperatorApp

/// Which sound the app makes for what.
final class OperatorSoundTests: XCTestCase {
    func testReadsStayQuiet() {
        XCTAssertNil(OperatorSound.forFinishedStep(named: "calendar.events"))
        XCTAssertNil(OperatorSound.forFinishedStep(named: "connections.read"))
    }

    func testAWritePlaysItsAppsNote() {
        XCTAssertEqual(OperatorSound.forFinishedStep(named: "sms.send"), .did(.gmail))
        XCTAssertEqual(OperatorSound.forFinishedStep(named: "calendar.create"), .did(.calendar))
        XCTAssertEqual(OperatorSound.forFinishedStep(named: "connections.write"), .did(.drive))
    }

    func testOnlyStepsThatJustFinishAreHeard() {
        let running = ChatActivityStep(id: "a", tool: "sms.send", arguments: [:], state: .running)
        let done = ChatActivityStep(id: "a", tool: "sms.send", arguments: [:], state: .done)
        XCTAssertEqual(OperatorSound.forNewlyFinished(before: [running], after: [done]), [.did(.gmail)])
        XCTAssertEqual(OperatorSound.forNewlyFinished(before: [done], after: [done]), [])
    }

    func testEveryFileIsInTheAppBundle() {
        let all: [OperatorSound] = [.send, .did(.calendar), .did(.gmail), .did(.maps), .did(.drive), .done, .needsYou, .committed, .leftIt, .unsure, .incoming]
        for sound in all {
            XCTAssertNotNil(Bundle.main.url(forResource: sound.fileName, withExtension: "wav"), sound.fileName)
        }
    }

    func testNeedsYouIsTheLoudestAndDidTheQuietest() {
        XCTAssertEqual(OperatorSound.needsYou.volume, 1)
        XCTAssertEqual(OperatorSound.did(.gmail).volume, 0.45)
    }
}
