import OperatorCore
import XCTest
@testable import OperatorApp

final class ConnectorSearchTests: XCTestCase {
    private func titles(_ query: String) -> [String] {
        ConnectorSearch.matches(in: ConnectorCatalog.all, query: query).map(\.title)
    }

    func testAnEmptyOrBlankQueryKeepsEverythingInOrder() {
        XCTAssertEqual(self.titles(""), ConnectorCatalog.all.map(\.title))
        XCTAssertEqual(self.titles("   "), ConnectorCatalog.all.map(\.title))
    }

    func testMatchesTheNameIgnoringCaseAndAccents() {
        XCTAssertEqual(self.titles("spot"), ["Spotify"])
        XCTAssertEqual(self.titles("SPOTIFY"), ["Spotify"])
        XCTAssertEqual(self.titles("spótify"), ["Spotify"])
    }

    func testAPartOfTheNameFindsEveryEntryThatHasIt() {
        XCTAssertEqual(self.titles("outlook"), ["Outlook Mail", "Outlook Calendar"])
    }

    func testAnAppNamedOnlyInTheDescriptionIsFound() {
        XCTAssertTrue(self.titles("gmail").contains("Google"))
    }

    func testNameMatchesComeBeforeDescriptionMatches() {
        let found = self.titles("calendar")
        XCTAssertEqual(Array(found.prefix(2)), ["Calendar", "Outlook Calendar"])
    }

    func testNothingMatchesNonsense() {
        XCTAssertEqual(self.titles("zzzqqq"), [])
    }
}
