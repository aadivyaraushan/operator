import Foundation

// Edits to files the owner already has in Google Drive: Sheet cells, Doc and
// Slides text, a text file's content, and a file's name, folder or creation.
// Like every other account write these run only after the owner's
// confirmation tap, as one fixed request that is never retried.

/// Rows of cell text for one range. Values are entered as if typed
/// (USER_ENTERED), so "12" becomes a number and "=A1" a formula.
struct GoogleSheetsCellsWrite: Sendable {
    let fileID: String
    /// A1 notation, e.g. "Signups!A2:B3", or just a tab name when appending.
    let range: String
    let rows: [[String]]
}

struct GoogleDocsAppendTextWrite: Sendable {
    let fileID: String
    let text: String
}

/// Replaces every case-sensitive match in a Doc or a Slides deck.
struct GoogleReplaceTextWrite: Sendable {
    let fileID: String
    let find: String
    let replacement: String
}

/// One new title-and-body slide at the end of the deck.
struct GoogleSlidesAddSlideWrite: Sendable {
    let fileID: String
    let title: String
    let body: String
}

struct GoogleDriveUpdateTextFileWrite: Sendable {
    let fileID: String
    let content: String
}

struct GoogleDriveRenameFileWrite: Sendable {
    let fileID: String
    let name: String
}

/// Drive moves a file by adding one parent folder and removing another; both
/// ids come from a Drive search's `parents`.
struct GoogleDriveMoveFileWrite: Sendable {
    let fileID: String
    let fromFolderID: String
    let toFolderID: String
}

struct GoogleDriveCreateFileWrite: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case document, spreadsheet, presentation, folder

        var mimeType: String { "application/vnd.google-apps.\(self.rawValue)" }
    }

    let name: String
    let kind: Kind
}

extension DirectAccountWriter {
    static let sheetMaximumRows = 500
    static let sheetMaximumColumns = 50

    static func workspaceInputShape(_ input: AccountWriteRequest) -> (fields: Int, bytes: Int) {
        switch input {
        case let .googleSheetsUpdateCells(value), let .googleSheetsAppendRows(value):
            (2 + value.rows.count, value.range.utf8.count + self.cellBytes(value.rows))
        case let .googleDocsAppendText(value):
            (2, value.text.utf8.count)
        case let .googleDocsReplaceText(value), let .googleSlidesReplaceText(value):
            (3, value.find.utf8.count + value.replacement.utf8.count)
        case let .googleSlidesAddSlide(value):
            (3, value.title.utf8.count + value.body.utf8.count)
        case let .googleDriveUpdateTextFile(value):
            (2, value.content.utf8.count)
        case let .googleDriveRenameFile(value):
            (2, value.name.utf8.count)
        case .googleDriveMoveFile:
            (3, 0)
        case let .googleDriveCreateFile(value):
            (2, value.name.utf8.count)
        default:
            (0, 0)
        }
    }

    static func workspaceIsValid(_ input: AccountWriteRequest) -> Bool {
        switch input {
        case let .googleSheetsUpdateCells(value), let .googleSheetsAppendRows(value):
            return self.validFileID(value.fileID)
                && self.validSingleLine(value.range, maxBytes: 256, required: true)
                && (1...self.sheetMaximumRows).contains(value.rows.count)
                && value.rows.allSatisfy { (1...self.sheetMaximumColumns).contains($0.count) && $0.allSatisfy { self.validBody($0, maxBytes: 50_000) } }
                && self.cellBytes(value.rows) <= 262_144
        case let .googleDocsAppendText(value):
            return self.validFileID(value.fileID) && self.validBody(value.text, maxBytes: 262_144) && !value.text.isEmpty
        case let .googleDocsReplaceText(value), let .googleSlidesReplaceText(value):
            return self.validFileID(value.fileID)
                && self.validBody(value.find, maxBytes: 4_096) && !value.find.isEmpty
                && self.validBody(value.replacement, maxBytes: 65_536)
        case let .googleSlidesAddSlide(value):
            return self.validFileID(value.fileID)
                && self.validSingleLine(value.title, maxBytes: 512, required: true)
                && self.validBody(value.body, maxBytes: 16_384)
        case let .googleDriveUpdateTextFile(value):
            return self.validFileID(value.fileID) && self.validBody(value.content, maxBytes: 262_144)
        case let .googleDriveRenameFile(value):
            return self.validFileID(value.fileID) && self.validSingleLine(value.name, maxBytes: 255, required: true)
        case let .googleDriveMoveFile(value):
            return self.validFileID(value.fileID) && self.validFileID(value.fromFolderID) && self.validFileID(value.toFolderID)
                && value.fromFolderID != value.toFolderID
        case let .googleDriveCreateFile(value):
            return self.validSingleLine(value.name, maxBytes: 255, required: true)
        default:
            return false
        }
    }

    /// nil for every operation that is not one of these.
    static func workspaceRequest(for input: AccountWriteRequest) throws -> URLRequest? {
        switch input {
        case let .googleSheetsUpdateCells(value):
            return try self.jsonRequest(
                "PUT", host: "sheets.googleapis.com", path: "/v4/spreadsheets/\(value.fileID)/values/\(self.pathSegment(value.range))",
                query: [("valueInputOption", "USER_ENTERED")],
                body: ["majorDimension": "ROWS", "values": value.rows])
        case let .googleSheetsAppendRows(value):
            return try self.jsonRequest(
                "POST", host: "sheets.googleapis.com", path: "/v4/spreadsheets/\(value.fileID)/values/\(self.pathSegment(value.range)):append",
                query: [("valueInputOption", "USER_ENTERED"), ("insertDataOption", "INSERT_ROWS")],
                body: ["majorDimension": "ROWS", "values": value.rows])
        case let .googleDocsAppendText(value):
            return try self.jsonRequest(
                "POST", host: "docs.googleapis.com", path: "/v1/documents/\(value.fileID):batchUpdate",
                body: ["requests": [["insertText": ["text": value.text, "endOfSegmentLocation": [String: Any]()]]]])
        case let .googleDocsReplaceText(value):
            return try self.jsonRequest(
                "POST", host: "docs.googleapis.com", path: "/v1/documents/\(value.fileID):batchUpdate",
                body: ["requests": [self.replaceAllText(value)]])
        case let .googleSlidesReplaceText(value):
            return try self.jsonRequest(
                "POST", host: "slides.googleapis.com", path: "/v1/presentations/\(value.fileID):batchUpdate",
                body: ["requests": [self.replaceAllText(value)]])
        case let .googleSlidesAddSlide(value):
            // The ids let the same request fill the boxes it just created.
            let mark = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let titleID = "operator_title_\(mark)"
            let bodyID = "operator_body_\(mark)"
            return try self.jsonRequest(
                "POST", host: "slides.googleapis.com", path: "/v1/presentations/\(value.fileID):batchUpdate",
                body: ["requests": [
                    ["createSlide": [
                        "slideLayoutReference": ["predefinedLayout": "TITLE_AND_BODY"],
                        "placeholderIdMappings": [
                            ["layoutPlaceholder": ["type": "TITLE", "index": 0], "objectId": titleID],
                            ["layoutPlaceholder": ["type": "BODY", "index": 0], "objectId": bodyID],
                        ],
                    ]],
                    ["insertText": ["objectId": titleID, "text": value.title]],
                    ["insertText": ["objectId": bodyID, "text": value.body]],
                ]])
        case let .googleDriveUpdateTextFile(value):
            var request = try self.emptyRequest(
                "PATCH", host: "www.googleapis.com", path: "/upload/drive/v3/files/\(value.fileID)",
                query: [("uploadType", "media"), ("fields", "id"), ("supportsAllDrives", "true")])
            request.httpBody = Data(value.content.utf8)
            request.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            return request
        case let .googleDriveRenameFile(value):
            return try self.jsonRequest(
                "PATCH", host: "www.googleapis.com", path: "/drive/v3/files/\(value.fileID)",
                query: [("fields", "id"), ("supportsAllDrives", "true")],
                body: ["name": value.name])
        case let .googleDriveMoveFile(value):
            return try self.jsonRequest(
                "PATCH", host: "www.googleapis.com", path: "/drive/v3/files/\(value.fileID)",
                query: [("addParents", value.toFolderID), ("removeParents", value.fromFolderID), ("fields", "id"), ("supportsAllDrives", "true")],
                body: [String: Any]())
        case let .googleDriveCreateFile(value):
            return try self.jsonRequest(
                "POST", host: "www.googleapis.com", path: "/drive/v3/files",
                query: [("fields", "id")],
                body: ["name": value.name, "mimeType": value.kind.mimeType])
        default:
            return nil
        }
    }

    static func workspaceReceipt(for input: AccountWriteRequest, object: [String: Any]) throws -> AccountWriteReceipt {
        switch input {
        case .googleSheetsUpdateCells, .googleSheetsAppendRows:
            // update answers at the top level, append nests the same fields.
            let updates = object["updates"] as? [String: Any] ?? object
            guard let range = updates["updatedRange"] as? String, self.validRemoteID(range, maxBytes: 512),
                  let cells = updates["updatedCells"] as? Int, cells >= 0
            else { throw AccountWriteError.invalidResponse }
            return .googleSheetCells(range: range, cells: cells)
        case let .googleDocsAppendText(value):
            return .googleFileEdited(id: try self.echoedID(object["documentId"], expected: value.fileID), occurrences: nil)
        case let .googleDocsReplaceText(value):
            return .googleFileEdited(id: try self.echoedID(object["documentId"], expected: value.fileID), occurrences: self.occurrencesChanged(object))
        case let .googleSlidesReplaceText(value):
            return .googleFileEdited(id: try self.echoedID(object["presentationId"], expected: value.fileID), occurrences: self.occurrencesChanged(object))
        case let .googleSlidesAddSlide(value):
            return .googleFileEdited(id: try self.echoedID(object["presentationId"], expected: value.fileID), occurrences: nil)
        default:
            throw AccountWriteError.invalidResponse
        }
    }

    /// Drive file and folder ids; nothing else is accepted into a URL path.
    private static func validFileID(_ value: String) -> Bool {
        self.matches(value, pattern: #"^[A-Za-z0-9_-]{1,256}$"#)
    }

    private static func cellBytes(_ rows: [[String]]) -> Int {
        rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } }
    }

    private static func echoedID(_ value: Any?, expected: String) throws -> String {
        guard let id = value as? String, id == expected else { throw AccountWriteError.invalidResponse }
        return id
    }

    /// Google leaves the count out when nothing matched.
    private static func occurrencesChanged(_ object: [String: Any]) -> Int {
        let replies = object["replies"] as? [[String: Any]] ?? []
        return (replies.first?["replaceAllText"] as? [String: Any])?["occurrencesChanged"] as? Int ?? 0
    }

    private static func replaceAllText(_ value: GoogleReplaceTextWrite) -> [String: Any] {
        ["replaceAllText": ["containsText": ["text": value.find, "matchCase": true], "replaceText": value.replacement]]
    }

    /// A range such as 'Q1/Q2 plan'!A1 must stay one path segment.
    private static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func emptyRequest(_ method: String, host: String, path: String, query: [(String, String)] = []) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw AccountWriteError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private static func jsonRequest(_ method: String, host: String, path: String, query: [(String, String)] = [], body: [String: Any]) throws -> URLRequest {
        var request = try self.emptyRequest(method, host: host, path: path, query: query)
        request.httpBody = try self.jsonData(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
