import SwiftUI
import XCTest
@testable import OperatorApp

/// The brand doc allows four colors; these are their exact values.
final class OperatorBrandTests: XCTestCase {
    func testTheFourColorsMatchTheBrandDoc() {
        XCTAssertEqual(OperatorBrand.hex(OperatorBrand.vermilionRGB), "#FF5934")
        XCTAssertEqual(OperatorBrand.hex(OperatorBrand.rustRGB), "#9E3924")
        XCTAssertEqual(OperatorBrand.hex(OperatorBrand.nearBlackRGB), "#0B0B0B")
        XCTAssertEqual(OperatorBrand.hex(OperatorBrand.lightRGB), "#E8E6E2")
    }
}
