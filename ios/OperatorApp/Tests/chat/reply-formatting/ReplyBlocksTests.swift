import XCTest
@testable import OperatorApp

final class ReplyBlocksTests: XCTestCase {
    func testPlainProseIsOneBlock() {
        XCTAssertEqual(ReplyBlocks.parse("Hello **there**."), [.prose([.text("Hello **there**.")])])
    }

    func testAFencedBlockBecomesCodeWithItsLanguageAndNoFences() {
        let reply = "Run this:\n```swift\nlet x = 1\nprint(x)\n```\nDone."
        XCTAssertEqual(ReplyBlocks.parse(reply), [
            .prose([.text("Run this:")]),
            .code(language: "swift", text: "let x = 1\nprint(x)"),
            .prose([.text("Done.")]),
        ])
    }

    func testAFenceWithNoLanguage() {
        XCTAssertEqual(ReplyBlocks.parse("```\nls -la\n```"), [.code(language: nil, text: "ls -la")])
    }

    func testAFenceStillStreamingIsCodeToTheEnd() {
        XCTAssertEqual(ReplyBlocks.parse("```python\nx = 1\ny ="), [.code(language: "python", text: "x = 1\ny =")])
    }

    func testMathAndDollarsInsideCodeAreLeftAlone() {
        XCTAssertEqual(
            ReplyBlocks.parse("```\necho $HOME \\( x \\) $$\n```"),
            [.code(language: nil, text: "echo $HOME \\( x \\) $$")])
    }

    func testDisplayMathInBracketsAndDoubleDollars() {
        XCTAssertEqual(ReplyBlocks.parse("So:\n\\[\n\\frac{a}{b}\n\\]\nand $$x^2$$ too."), [
            .prose([.text("So:")]),
            .math("\\frac{a}{b}"),
            .prose([.text("and")]),
            .math("x^2"),
            .prose([.text("too.")]),
        ])
    }

    func testInlineMathInParensAndSingleDollars() {
        XCTAssertEqual(ReplyBlocks.parse("Since \\(a^2\\) and $b_1$ hold."), [
            .prose([.text("Since "), .math("a^2"), .text(" and "), .math("b_1"), .text(" hold.")]),
        ])
    }

    func testMoneyIsNotMath() {
        XCTAssertEqual(
            ReplyBlocks.parse("It costs $5 now and $10 later."),
            [.prose([.text("It costs $5 now and $10 later.")])])
        XCTAssertEqual(ReplyBlocks.parse("Just $ 3 $ here"), [.prose([.text("Just $ 3 $ here")])])
    }

    func testInlineCodeIsNotSearchedForMath() {
        XCTAssertEqual(
            ReplyBlocks.parse("Use `$x$` literally, then $y$."),
            [.prose([.text("Use `$x$` literally, then "), .math("y"), .text(".")])])
    }

    func testMathStillStreamingStaysAsText() {
        XCTAssertEqual(ReplyBlocks.parse("We get \\(x +"), [.prose([.text("We get \\(x +")])])
        XCTAssertEqual(ReplyBlocks.parse("We get \\[ x +"), [.prose([.text("We get \\[ x +")])])
    }

    func testBlankLinesAroundBlocksDoNotMakeEmptyProse() {
        XCTAssertEqual(ReplyBlocks.parse("A\n\n```\nb\n```\n\nC"), [
            .prose([.text("A")]), .code(language: nil, text: "b"), .prose([.text("C")]),
        ])
    }

    func testParagraphBreaksInsideProseAreKept() {
        XCTAssertEqual(ReplyBlocks.parse("One\n\nTwo"), [.prose([.text("One\n\nTwo")])])
    }
}
