import Foundation
import XCTest
@testable import OperatorApp

/// The owner wants Operator to change what is inside their Drive, not only
/// make new text files: Sheet cells, Doc and Slides text, a text file's
/// content, and a file's name or folder. Each is one fixed request.
final class GoogleWorkspaceWriterTests: XCTestCase {
    private func send(_ input: AccountWriteRequest, body: String) async throws -> (AccountWriteReceipt, URLRequest) {
        let transport = WorkspaceFixtureTransport(body: body)
        let writer = DirectAccountWriter(transport: transport, bearer: { provider in
            XCTAssertEqual(provider, .google)
            return "token"
        })
        let receipt = try await writer.writeAfterOwnerConfirmation(input)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        return (receipt, try XCTUnwrap(requests.first))
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testSheetCellsAreOverwrittenInPlaceAsIfTyped() async throws {
        let (receipt, request) = try await self.send(
            .googleSheetsUpdateCells(.init(fileID: "S1", range: "Signups!A2:B3", rows: [["a@example.com", "12"], ["b@example.com", "=A1"]])),
            body: #"{"spreadsheetId":"S1","updatedRange":"Signups!A2:B3","updatedRows":2,"updatedColumns":2,"updatedCells":4}"#)
        XCTAssertEqual(receipt, .googleSheetCells(range: "Signups!A2:B3", cells: 4))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.host, "sheets.googleapis.com")
        XCTAssertEqual(request.url?.path, "/v4/spreadsheets/S1/values/Signups!A2:B3")
        XCTAssertEqual(self.query(request), ["valueInputOption": "USER_ENTERED"])
        let body = try self.json(request)
        XCTAssertEqual(body["values"] as? [[String]], [["a@example.com", "12"], ["b@example.com", "=A1"]])
        XCTAssertEqual(body["majorDimension"] as? String, "ROWS")
    }

    func testSheetRowsAreAppendedAsNewRowsBelowTheTable() async throws {
        let (receipt, request) = try await self.send(
            .googleSheetsAppendRows(.init(fileID: "S1", range: "Signups", rows: [["c@example.com", "wed"]])),
            body: #"{"spreadsheetId":"S1","tableRange":"Signups!A1:B3","updates":{"updatedRange":"Signups!A4:B4","updatedCells":2}}"#)
        XCTAssertEqual(receipt, .googleSheetCells(range: "Signups!A4:B4", cells: 2))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v4/spreadsheets/S1/values/Signups:append")
        XCTAssertEqual(self.query(request), ["valueInputOption": "USER_ENTERED", "insertDataOption": "INSERT_ROWS"])
        XCTAssertEqual(try self.json(request)["values"] as? [[String]], [["c@example.com", "wed"]])
    }

    func testARangeWithSpacesOrASlashStaysInsideItsPathSegment() async throws {
        let (_, request) = try await self.send(
            .googleSheetsUpdateCells(.init(fileID: "S1", range: "'Q1/Q2 plan'!A1", rows: [["x"]])),
            body: #"{"updatedRange":"'Q1/Q2 plan'!A1","updatedCells":1}"#)
        let raw = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(raw.contains("/values/'Q1%2FQ2%20plan'!A1?") || raw.contains("/values/%27Q1%2FQ2%20plan%27!A1?") || raw.contains("/values/%27Q1%2FQ2%20plan%27%21A1?"), raw)
    }

    func testDocTextIsAddedAtTheEndOfTheDocument() async throws {
        let (receipt, request) = try await self.send(
            .googleDocsAppendText(.init(fileID: "D1", text: "\nNew line")),
            body: #"{"documentId":"D1","replies":[{}]}"#)
        XCTAssertEqual(receipt, .googleFileEdited(id: "D1", occurrences: nil))
        XCTAssertEqual(request.url?.absoluteString, "https://docs.googleapis.com/v1/documents/D1:batchUpdate")
        XCTAssertEqual(request.httpMethod, "POST")
        let requests = try XCTUnwrap(try self.json(request)["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 1)
        let insert = try XCTUnwrap(requests[0]["insertText"] as? [String: Any])
        XCTAssertEqual(insert["text"] as? String, "\nNew line")
        XCTAssertNotNil(insert["endOfSegmentLocation"] as? [String: Any])
    }

    func testDocAndSlidesTextIsReplacedEverywhereAndTheCountComesBack() async throws {
        let (docReceipt, doc) = try await self.send(
            .googleDocsReplaceText(.init(fileID: "D1", find: "draft", replacement: "final")),
            body: #"{"documentId":"D1","replies":[{"replaceAllText":{"occurrencesChanged":3}}]}"#)
        XCTAssertEqual(docReceipt, .googleFileEdited(id: "D1", occurrences: 3))
        let docReplace = try XCTUnwrap((try self.json(doc)["requests"] as? [[String: Any]])?.first?["replaceAllText"] as? [String: Any])
        XCTAssertEqual(docReplace["replaceText"] as? String, "final")
        XCTAssertEqual((docReplace["containsText"] as? [String: Any])?["text"] as? String, "draft")
        XCTAssertEqual((docReplace["containsText"] as? [String: Any])?["matchCase"] as? Bool, true)

        // Google leaves occurrencesChanged out when nothing matched.
        let (deckReceipt, deck) = try await self.send(
            .googleSlidesReplaceText(.init(fileID: "P1", find: "2025", replacement: "2026")),
            body: #"{"presentationId":"P1","replies":[{"replaceAllText":{}}]}"#)
        XCTAssertEqual(deckReceipt, .googleFileEdited(id: "P1", occurrences: 0))
        XCTAssertEqual(deck.url?.absoluteString, "https://slides.googleapis.com/v1/presentations/P1:batchUpdate")
    }

    func testANewSlideIsAddedAtTheEndWithItsTitleAndBody() async throws {
        let (receipt, request) = try await self.send(
            .googleSlidesAddSlide(.init(fileID: "P1", title: "Roadmap", body: "Ship it")),
            body: #"{"presentationId":"P1","replies":[{"createSlide":{"objectId":"x"}},{},{}]}"#)
        XCTAssertEqual(receipt, .googleFileEdited(id: "P1", occurrences: nil))
        let requests = try XCTUnwrap(try self.json(request)["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 3)
        let create = try XCTUnwrap(requests[0]["createSlide"] as? [String: Any])
        XCTAssertEqual((create["slideLayoutReference"] as? [String: Any])?["predefinedLayout"] as? String, "TITLE_AND_BODY")
        let mappings = try XCTUnwrap(create["placeholderIdMappings"] as? [[String: Any]])
        let ids = mappings.compactMap { $0["objectId"] as? String }
        XCTAssertEqual(ids.count, 2)
        let inserts = requests.dropFirst().compactMap { $0["insertText"] as? [String: Any] }
        XCTAssertEqual(inserts.map { $0["objectId"] as? String }, ids)
        XCTAssertEqual(inserts.map { $0["text"] as? String }, ["Roadmap", "Ship it"])
    }

    func testATextFilesContentIsReplacedWithoutTouchingItsName() async throws {
        let (receipt, request) = try await self.send(
            .googleDriveUpdateTextFile(.init(fileID: "F1", content: "new body")),
            body: #"{"id":"F1"}"#)
        XCTAssertEqual(receipt, .googleDriveFile(id: "F1"))
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/upload/drive/v3/files/F1")
        XCTAssertEqual(self.query(request), ["uploadType": "media", "fields": "id", "supportsAllDrives": "true"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=UTF-8")
        XCTAssertEqual(request.httpBody, Data("new body".utf8))
    }

    func testRenameMoveAndCreateUseTheDriveFilesEndpoint() async throws {
        let (_, rename) = try await self.send(.googleDriveRenameFile(.init(fileID: "F1", name: "Waitlist v2")), body: #"{"id":"F1"}"#)
        XCTAssertEqual(rename.httpMethod, "PATCH")
        XCTAssertEqual(rename.url?.path, "/drive/v3/files/F1")
        XCTAssertEqual(try self.json(rename) as? [String: String], ["name": "Waitlist v2"])

        let (_, move) = try await self.send(.googleDriveMoveFile(.init(fileID: "F1", fromFolderID: "P1", toFolderID: "P2")), body: #"{"id":"F1"}"#)
        XCTAssertEqual(move.httpMethod, "PATCH")
        XCTAssertEqual(self.query(move), ["addParents": "P2", "removeParents": "P1", "fields": "id", "supportsAllDrives": "true"])

        for (kind, mime) in [(GoogleDriveCreateFileWrite.Kind.document, "application/vnd.google-apps.document"),
                             (.spreadsheet, "application/vnd.google-apps.spreadsheet"),
                             (.presentation, "application/vnd.google-apps.presentation"),
                             (.folder, "application/vnd.google-apps.folder")] {
            let (receipt, create) = try await self.send(.googleDriveCreateFile(.init(name: "Plan", kind: kind)), body: #"{"id":"N1"}"#)
            XCTAssertEqual(receipt, .googleDriveFile(id: "N1"))
            XCTAssertEqual(create.httpMethod, "POST")
            XCTAssertEqual(create.url?.path, "/drive/v3/files")
            XCTAssertEqual(try self.json(create) as? [String: String], ["name": "Plan", "mimeType": mime])
        }
    }

    func testBadIDsEmptyEditsAndOversizedTablesAreRefusedBeforeAnyRequest() async {
        let wide = Array(repeating: "x", count: 51)
        let bad: [AccountWriteRequest] = [
            .googleSheetsUpdateCells(.init(fileID: "a/b", range: "A1", rows: [["x"]])),
            .googleSheetsUpdateCells(.init(fileID: "S1", range: "", rows: [["x"]])),
            .googleSheetsUpdateCells(.init(fileID: "S1", range: "A1\nB2", rows: [["x"]])),
            .googleSheetsUpdateCells(.init(fileID: "S1", range: "A1", rows: [])),
            .googleSheetsAppendRows(.init(fileID: "S1", range: "A1", rows: [wide])),
            .googleSheetsAppendRows(.init(fileID: "S1", range: "A1", rows: Array(repeating: ["x"], count: 501))),
            .googleDocsAppendText(.init(fileID: "D1", text: "")),
            .googleDocsReplaceText(.init(fileID: "D1", find: "", replacement: "x")),
            .googleSlidesReplaceText(.init(fileID: "../P1", find: "a", replacement: "b")),
            .googleSlidesAddSlide(.init(fileID: "P1", title: "", body: "")),
            .googleDriveRenameFile(.init(fileID: "F1", name: "bad\nname")),
            .googleDriveMoveFile(.init(fileID: "F1", fromFolderID: "P1", toFolderID: "P1")),
            .googleDriveMoveFile(.init(fileID: "F1", fromFolderID: "P 1", toFolderID: "P2")),
            .googleDriveCreateFile(.init(name: "", kind: .document)),
        ]
        for input in bad {
            let transport = WorkspaceFixtureTransport(body: "{}")
            let writer = DirectAccountWriter(transport: transport, bearer: { _ in "token" })
            do { _ = try await writer.writeAfterOwnerConfirmation(input); XCTFail("expected refusal for \(input)") }
            catch { XCTAssertEqual(error as? AccountWriteError, .invalidRequest, "\(input)") }
            let calls = await transport.requests.count
            XCTAssertEqual(calls, 0, "\(input)")
        }
    }

    func testEveryNewOperationBelongsToGoogle() {
        for operation in AccountWriteOperation.allCases where operation.rawValue.hasPrefix("google") {
            XCTAssertEqual(operation.provider, .google, operation.rawValue)
        }
    }
}

private actor WorkspaceFixtureTransport: PhoneHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let body: String
    init(body: String) { self.body = body }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
