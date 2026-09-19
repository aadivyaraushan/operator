import Foundation
import XCTest
@testable import OperatorApp

/// The owner asked "how many sign-ups are on my Operator waitlist sheet" and
/// got "no matching files": the drive.file scope only ever shows files
/// Operator made itself, and nothing could read a sheet's cells. These cover
/// finding any file and reading what is inside a Sheet, a Doc, a Slides deck
/// and a plain text file.
final class GoogleDriveContentReaderTests: XCTestCase {
    private func content(_ fileID: String, range: String? = nil) -> AccountReadRequest {
        .init(operation: .googleDriveFileContent, query: range, channel: nil, timeMin: nil, timeMax: nil, limit: 1, cursor: nil, fileID: fileID)
    }

    private func row(_ page: AccountReadPage) throws -> [String: Any] {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.payloadJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(rows.first)
    }

    func testGoogleScopeReachesEveryDriveFileForReadingAndWriting() {
        let scopes = OAuthProvider.google.scopes
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/drive"))
        XCTAssertFalse(scopes.contains("https://www.googleapis.com/auth/drive.file"), "drive.file hides every file Operator did not create")
    }

    func testSearchLooksInsideFilesAndReturnsWhatIsNeededToOpenOrMoveThem() async throws {
        let transport = DriveFixtureTransport(metadata: "", content: #"{"files":[{"id":"F1","name":"Operator waitlist","mimeType":"application/vnd.google-apps.spreadsheet","modifiedTime":"2026-09-16T00:00:00Z","webViewLink":"https://docs.google.com/x","parents":["P1"],"owners":[{"emailAddress":"x@example.com"}]}]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let page = try await reader.read(.init(operation: .googleDriveFiles, query: "Operator waitlist", channel: nil, timeMin: nil, timeMax: nil, limit: 5, cursor: nil))
        let seen = await transport.urls
        let url = try XCTUnwrap(seen.first)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "(name contains 'Operator waitlist' or fullText contains 'Operator waitlist') and trashed = false")
        let found = try self.row(page)
        XCTAssertEqual(Set(found.keys), ["id", "name", "mimeType", "modifiedTime", "webViewLink", "parents"])
    }

    func testASheetWithNoRangeComesBackAsTheCSVOfItsFirstTab() async throws {
        let transport = DriveFixtureTransport(
            metadata: #"{"id":"S1","name":"Operator waitlist","mimeType":"application/vnd.google-apps.spreadsheet"}"#,
            content: "email,when\na@example.com,mon\nb@example.com,tue\n")
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let found = try self.row(try await reader.read(self.content("S1")))
        let urls = await transport.urls
        XCTAssertEqual(urls.map(\.path), ["/drive/v3/files/S1", "/drive/v3/files/S1/export"])
        XCTAssertEqual(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mimeType" }?.value, "text/csv")
        XCTAssertEqual(found["name"] as? String, "Operator waitlist")
        XCTAssertEqual(found["content"] as? String, "email,when\na@example.com,mon\nb@example.com,tue\n")
        XCTAssertEqual(found["truncated"] as? Bool, false)
    }

    func testASheetWithARangeIsReadThroughTheSheetsAPIAsRows() async throws {
        let transport = DriveFixtureTransport(
            metadata: #"{"id":"S1","name":"W","mimeType":"application/vnd.google-apps.spreadsheet"}"#,
            content: #"{"range":"Signups!A1:B2","majorDimension":"ROWS","values":[["email","when"],["a@example.com","mon"]]}"#)
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let found = try self.row(try await reader.read(self.content("S1", range: "Signups!A1:B2")))
        let seen = await transport.urls
        let last = try XCTUnwrap(seen.last)
        XCTAssertEqual(last.host, "sheets.googleapis.com")
        XCTAssertEqual(last.path, "/v4/spreadsheets/S1/values/Signups!A1:B2")
        XCTAssertEqual(found["range"] as? String, "Signups!A1:B2")
        XCTAssertEqual(found["rows"] as? [[String]], [["email", "when"], ["a@example.com", "mon"]])
    }

    func testDocsAndSlidesExportAsPlainTextAndTextFilesDownloadAsTheyAre() async throws {
        for (mime, path, parameter) in [
            ("application/vnd.google-apps.document", "/drive/v3/files/D1/export", "mimeType=text/plain"),
            ("application/vnd.google-apps.presentation", "/drive/v3/files/D1/export", "mimeType=text/plain"),
            ("text/plain", "/drive/v3/files/D1", "alt=media"),
        ] {
            let transport = DriveFixtureTransport(metadata: #"{"id":"D1","name":"N","mimeType":"\#(mime)"}"#, content: "hello")
            let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
            let found = try self.row(try await reader.read(self.content("D1")))
            let seen = await transport.urls
        let last = try XCTUnwrap(seen.last)
            XCTAssertEqual(last.path, path, mime)
            XCTAssertEqual(last.query?.removingPercentEncoding, parameter, mime)
            XCTAssertEqual(found["content"] as? String, "hello", mime)
        }
    }

    func testAFileWithNoTextFormIsNamedAsUnsupportedWithoutDownloadingIt() async throws {
        let transport = DriveFixtureTransport(metadata: #"{"id":"I1","name":"photo.png","mimeType":"image/png"}"#, content: "never")
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let found = try self.row(try await reader.read(self.content("I1")))
        XCTAssertEqual(found["unsupported"] as? Bool, true)
        XCTAssertNil(found["content"])
        let calls = await transport.urls.count
        XCTAssertEqual(calls, 1)
    }

    func testLongContentIsCutAndSaysSo() async throws {
        let transport = DriveFixtureTransport(metadata: #"{"id":"D1","name":"N","mimeType":"text/plain"}"#, content: String(repeating: "x", count: 300_000))
        let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
        let found = try self.row(try await reader.read(self.content("D1")))
        XCTAssertEqual((found["content"] as? String)?.count, DirectAccountReader.driveContentMaximumCharacters)
        XCTAssertEqual(found["truncated"] as? Bool, true)
    }

    func testAFileIDThatCouldLeaveItsPathSegmentIsRefusedBeforeAnyRequest() async {
        for bad in ["", "a/b", "../x", "a?b", "a b"] {
            let transport = DriveFixtureTransport(metadata: "{}", content: "")
            let reader = DirectAccountReader(transport: transport, bearer: { _ in "token" })
            do { _ = try await reader.read(self.content(bad)); XCTFail("expected refusal for \(bad)") }
            catch { XCTAssertEqual(error as? AccountReadError, .invalidRequest, bad) }
            let calls = await transport.urls.count
            XCTAssertEqual(calls, 0, bad)
        }
    }
}

/// Answers the metadata call (the bare file path with a `fields` query) with
/// one body and every other call with the other.
private actor DriveFixtureTransport: PhoneHTTPTransport {
    private(set) var urls: [URL] = []
    private let metadata: String
    private let content: String
    init(metadata: String, content: String) { self.metadata = metadata; self.content = content }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        self.urls.append(url)
        let isMetadata = url.path.hasPrefix("/drive/v3/files/") && !url.path.hasSuffix("/export") && (url.query ?? "").contains("fields=")
        return (Data((isMetadata ? self.metadata : self.content).utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
