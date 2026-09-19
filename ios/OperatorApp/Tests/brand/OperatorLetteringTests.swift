import XCTest
@testable import OperatorApp

/// Lettering is drawn at 94% width and must still fill the space it is given.
final class OperatorLetteringTests: XCTestCase {
    func testContentIsOfferedExtraWidthSoItFillsItsSpaceOnceNarrowed() throws {
        let offered = try XCTUnwrap(OperatorLettering.widthToOffer(for: 376))
        XCTAssertEqual(offered, 400, accuracy: 0.001)
        XCTAssertEqual(OperatorLettering.widthTaken(by: offered), 376, accuracy: 0.001)
    }

    func testNoWidthOfferedStaysNoWidth() {
        XCTAssertNil(OperatorLettering.widthToOffer(for: nil))
    }

    func testTheThreeWeightsAreInTheAppBundle() {
        for weight in [OperatorLettering.Weight.regular, .medium, .bold] {
            XCTAssertNotNil(UIFont(name: weight.rawValue, size: 12), weight.rawValue)
        }
    }
}
