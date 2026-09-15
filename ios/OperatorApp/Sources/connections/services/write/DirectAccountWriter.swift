import Foundation
import OSLog

// This surface intentionally contains only the write operations already used by
// Operator's Android/companion adapters. It is called only by the native owner-
// confirmation handler; it is not registered as an OpenClaw node command.
enum AccountWriteOperation: String, CaseIterable, Sendable {
    case googleCalendarCreateEvent
    case googleCalendarUpdateEvent
    case googleDriveCreateTextFile
    case outlookCreateDraft
    case outlookSendMail
    case slackPostMessage
    case spotifyStartPlayback

    var provider: OAuthProvider {
        switch self {
        case .googleCalendarCreateEvent, .googleCalendarUpdateEvent, .googleDriveCreateTextFile:
            .google
        case .outlookCreateDraft, .outlookSendMail:
            .microsoftOutlook
        case .slackPostMessage:
            .slack
        case .spotifyStartPlayback:
            .spotify
        }
    }
}

struct GoogleCalendarCreateEventWrite: Sendable {
    let summary: String
    let description: String
    let startRFC3339: String
    let endRFC3339: String
    /// Email addresses to invite. Google sends each an invitation when the
    /// event is created (sendUpdates=all), so the owner sees them on the card.
    let attendees: [String]
    /// Ask Google to attach a Meet conference. The link comes back in the receipt.
    let addMeetLink: Bool

    init(summary: String, description: String, startRFC3339: String, endRFC3339: String, attendees: [String] = [], addMeetLink: Bool = false) {
        self.summary = summary
        self.description = description
        self.startRFC3339 = startRFC3339
        self.endRFC3339 = endRFC3339
        self.attendees = attendees
        self.addMeetLink = addMeetLink
    }
}

/// A PATCH of one existing event: only the fields given are sent, and
/// Google leaves the rest as they were. `attendees` replaces the whole guest
/// list (that is what the API does), so a caller adding one guest must pass
/// the existing ones too; the calendar read returns them.
struct GoogleCalendarUpdateEventWrite: Sendable {
    let eventID: String
    let summary: String?
    let description: String?
    let startRFC3339: String?
    let endRFC3339: String?
    let attendees: [String]?
    /// True adds a Meet conference to an event that has none. There is no
    /// "remove": false is the same as absent.
    let addMeetLink: Bool

    init(eventID: String, summary: String?, description: String?, startRFC3339: String?, endRFC3339: String?, attendees: [String]?, addMeetLink: Bool = false) {
        self.eventID = eventID
        self.summary = summary
        self.description = description
        self.startRFC3339 = startRFC3339
        self.endRFC3339 = endRFC3339
        self.attendees = attendees
        self.addMeetLink = addMeetLink
    }

    var isEmpty: Bool {
        self.summary == nil && self.description == nil && self.startRFC3339 == nil && self.endRFC3339 == nil && self.attendees == nil && !self.addMeetLink
    }
}

struct GoogleDriveCreateTextFileWrite: Sendable {
    let name: String
    let content: String
}

struct OutlookCreateDraftWrite: Sendable {
    let subject: String
    let body: String
}

struct OutlookSendMailWrite: Sendable {
    let to: String
    let subject: String
    let body: String
}

struct SlackPostMessageWrite: Sendable {
    let channelID: String
    let text: String
}

struct SpotifyStartPlaybackWrite: Sendable {
    let trackURI: String
    let deviceID: String?
}

enum AccountWriteRequest: Sendable {
    case googleCalendarCreateEvent(GoogleCalendarCreateEventWrite)
    case googleCalendarUpdateEvent(GoogleCalendarUpdateEventWrite)
    case googleDriveCreateTextFile(GoogleDriveCreateTextFileWrite)
    case outlookCreateDraft(OutlookCreateDraftWrite)
    case outlookSendMail(OutlookSendMailWrite)
    case slackPostMessage(SlackPostMessageWrite)
    case spotifyStartPlayback(SpotifyStartPlaybackWrite)

    var operation: AccountWriteOperation {
        switch self {
        case .googleCalendarCreateEvent: .googleCalendarCreateEvent
        case .googleCalendarUpdateEvent: .googleCalendarUpdateEvent
        case .googleDriveCreateTextFile: .googleDriveCreateTextFile
        case .outlookCreateDraft: .outlookCreateDraft
        case .outlookSendMail: .outlookSendMail
        case .slackPostMessage: .slackPostMessage
        case .spotifyStartPlayback: .spotifyStartPlayback
        }
    }
}

enum AccountWriteReceipt: Equatable, Sendable {
    /// meetLink is the event's Google Meet URL when the event has one.
    case googleCalendarEvent(id: String, meetLink: String? = nil)
    case googleDriveFile(id: String)
    case outlookDraft(id: String)
    case outlookMailAccepted
    case slackMessage(channelID: String, timestamp: String)
    case spotifyPlaybackStarted
}

enum AccountWriteError: Error, Equatable, Sendable {
    case invalidRequest
    case notConnected
    case permissionDenied
    case rateLimited(retryAfterSeconds: Int)
    case rejected(statusCode: Int)
    case invalidResponse
    case outcomeUnknownNotSafeToRetry(operation: AccountWriteOperation)
}

actor DirectAccountWriter {
    private let transport: any PhoneHTTPTransport
    private let bearer: @Sendable (OAuthProvider) async throws -> String
    private let logger = Logger(subsystem: "app.operator.ios", category: "account-write")

    init(
        transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport(),
        bearer: @escaping @Sendable (OAuthProvider) async throws -> String
    ) {
        self.transport = transport
        self.bearer = bearer
    }

    /// Performs one fixed provider request after the app's native owner-confirmation
    /// handler has approved the typed request. This method never retries.
    func writeAfterOwnerConfirmation(_ input: AccountWriteRequest) async throws -> AccountWriteReceipt {
        let operation = input.operation
        let shape = Self.inputShape(input)
        self.logger.info(
            "[account-write] input operation=\(operation.rawValue, privacy: .public) field_count=\(shape.fields) content_bytes=\(shape.bytes)"
        )

        guard Self.isValid(input) else {
            self.logger.error(
                "[account-write] refused operation=\(operation.rawValue, privacy: .public) error_code=invalid_request"
            )
            throw AccountWriteError.invalidRequest
        }
        try Task.checkCancellation()

        let token: String
        do {
            token = try await self.bearer(operation.provider)
        } catch is CancellationError {
            self.logger.info("[account-write] cancelled stage=bearer")
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            self.logger.info("[account-write] cancelled stage=bearer")
            throw error
        } catch {
            self.logger.error(
                "[account-write] refused operation=\(operation.rawValue, privacy: .public) error_code=not_connected"
            )
            throw AccountWriteError.notConnected
        }
        guard Self.validBearer(token) else {
            self.logger.error(
                "[account-write] refused operation=\(operation.rawValue, privacy: .public) error_code=not_connected"
            )
            throw AccountWriteError.notConnected
        }
        try Task.checkCancellation()

        var request = try Self.request(for: input)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        self.logger.info(
            "[account-write] request provider=\(operation.provider.rawValue, privacy: .public) operation=\(operation.rawValue, privacy: .public) method=\(request.httpMethod ?? "", privacy: .public) request_bytes=\(request.httpBody?.count ?? 0)"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.transport.data(for: request)
        } catch {
            self.logger.error(
                "[account-write] failed operation=\(operation.rawValue, privacy: .public) error_code=outcome_unknown"
            )
            throw AccountWriteError.outcomeUnknownNotSafeToRetry(operation: operation)
        }

        guard let http = response as? HTTPURLResponse else {
            self.logger.error(
                "[account-write] failed operation=\(operation.rawValue, privacy: .public) error_code=outcome_unknown"
            )
            throw AccountWriteError.outcomeUnknownNotSafeToRetry(operation: operation)
        }
        self.logger.info(
            "[account-write] response operation=\(operation.rawValue, privacy: .public) status=\(http.statusCode) response_bytes=\(data.count)"
        )
        try Self.checkStatus(http, operation: operation)
        guard data.count <= 65_536 else {
            self.logger.error(
                "[account-write] failed operation=\(operation.rawValue, privacy: .public) error_code=outcome_unknown_after_success"
            )
            throw AccountWriteError.outcomeUnknownNotSafeToRetry(operation: operation)
        }

        let receipt: AccountWriteReceipt
        do {
            receipt = try Self.receipt(for: input, data: data)
        } catch AccountWriteError.invalidResponse {
            self.logger.error(
                "[account-write] failed operation=\(operation.rawValue, privacy: .public) error_code=outcome_unknown_after_success"
            )
            throw AccountWriteError.outcomeUnknownNotSafeToRetry(operation: operation)
        }
        self.logger.info(
            "[account-write] complete operation=\(operation.rawValue, privacy: .public) receipt_fields=\(Self.receiptFieldCount(receipt))"
        )
        return receipt
    }

    private static func inputShape(_ input: AccountWriteRequest) -> (fields: Int, bytes: Int) {
        switch input {
        case let .googleCalendarCreateEvent(value):
            (4 + value.attendees.count, value.summary.utf8.count + value.description.utf8.count + value.startRFC3339.utf8.count + value.endRFC3339.utf8.count + value.attendees.reduce(0) { $0 + $1.utf8.count })
        case let .googleCalendarUpdateEvent(value):
            ([value.summary, value.description, value.startRFC3339, value.endRFC3339].compactMap { $0 }.count + (value.attendees?.count ?? 0) + 1,
             [value.eventID, value.summary ?? "", value.description ?? "", value.startRFC3339 ?? "", value.endRFC3339 ?? ""].reduce(0) { $0 + $1.utf8.count } + (value.attendees ?? []).reduce(0) { $0 + $1.utf8.count })
        case let .googleDriveCreateTextFile(value):
            (2, value.name.utf8.count + value.content.utf8.count)
        case let .outlookCreateDraft(value):
            (2, value.subject.utf8.count + value.body.utf8.count)
        case let .outlookSendMail(value):
            (3, value.to.utf8.count + value.subject.utf8.count + value.body.utf8.count)
        case let .slackPostMessage(value):
            (2, value.channelID.utf8.count + value.text.utf8.count)
        case let .spotifyStartPlayback(value):
            (value.deviceID == nil ? 1 : 2, value.trackURI.utf8.count + (value.deviceID?.utf8.count ?? 0))
        }
    }

    static func isValid(_ input: AccountWriteRequest) -> Bool {
        switch input {
        case let .googleCalendarCreateEvent(value):
            guard self.validSingleLine(value.summary, maxBytes: 512, required: true),
                  self.validBody(value.description, maxBytes: 16_384),
                  value.startRFC3339.utf8.count <= 64,
                  value.endRFC3339.utf8.count <= 64,
                  let start = self.rfc3339(value.startRFC3339),
                  let end = self.rfc3339(value.endRFC3339)
            else { return false }
            return start < end && self.validAttendees(value.attendees)
        case let .googleCalendarUpdateEvent(value):
            guard !value.isEmpty, self.validEventID(value.eventID) else { return false }
            if let summary = value.summary, !self.validSingleLine(summary, maxBytes: 512, required: true) { return false }
            if let description = value.description, !self.validBody(description, maxBytes: 16_384) { return false }
            // A time change needs both ends so the order can be checked here
            // rather than discovered as a provider rejection.
            switch (value.startRFC3339, value.endRFC3339) {
            case (nil, nil): break
            case let (startText?, endText?):
                guard startText.utf8.count <= 64, endText.utf8.count <= 64,
                      let start = self.rfc3339(startText), let end = self.rfc3339(endText), start < end
                else { return false }
            default: return false
            }
            if let attendees = value.attendees, !self.validAttendees(attendees) { return false }
            return true
        case let .googleDriveCreateTextFile(value):
            return self.validSingleLine(value.name, maxBytes: 255, required: true)
                && self.validBody(value.content, maxBytes: 262_144)
        case let .outlookCreateDraft(value):
            return self.validSingleLine(value.subject, maxBytes: 512, required: true)
                && self.validBody(value.body, maxBytes: 32_768)
        case let .outlookSendMail(value):
            return self.validEmail(value.to)
                && self.validSingleLine(value.subject, maxBytes: 512, required: true)
                && self.validBody(value.body, maxBytes: 32_768, required: true)
        case let .slackPostMessage(value):
            return self.matches(value.channelID, pattern: #"^[CDG][A-Z0-9]{1,99}$"#)
                && self.validBody(value.text, maxBytes: 4_000, required: true)
        case let .spotifyStartPlayback(value):
            guard self.matches(value.trackURI, pattern: #"^spotify:track:[A-Za-z0-9]{22}$"#) else { return false }
            guard let deviceID = value.deviceID else { return true }
            return self.matches(deviceID, pattern: #"^[A-Za-z0-9]{1,128}$"#)
        }
    }

    private static func validBearer(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384 && !token.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validSingleLine(_ value: String, maxBytes: Int, required: Bool) -> Bool {
        guard value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validBody(_ value: String, maxBytes: Int, required: Bool = false) -> Bool {
        guard value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        return !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Up to 50 distinct addresses, each a plain email. Duplicates are refused
    /// so the card the owner reads lists each guest once.
    private static func validAttendees(_ attendees: [String]) -> Bool {
        guard attendees.count <= 50, attendees.allSatisfy(self.validEmail) else { return false }
        return Set(attendees.map { $0.lowercased() }).count == attendees.count
    }

    /// Google event ids are base32hex, and recurring instances append
    /// _<timestamp>; nothing else is accepted into the URL path.
    private static func validEventID(_ value: String) -> Bool {
        self.matches(value, pattern: #"^[A-Za-z0-9_-]{1,1024}$"#)
    }

    private static func validEmail(_ value: String) -> Bool {
        value.utf8.count <= 320
            && self.matches(value, pattern: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func rfc3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func request(for input: AccountWriteRequest) throws -> URLRequest {
        let url: URL
        let method: String
        let body: Data
        let contentType: String

        switch input {
        case let .googleCalendarCreateEvent(value):
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
            var event: [String: Any] = [
                "summary": value.summary,
                "description": value.description,
                "start": ["dateTime": value.startRFC3339],
                "end": ["dateTime": value.endRFC3339],
            ]
            var query: [URLQueryItem] = []
            if !value.attendees.isEmpty {
                event["attendees"] = value.attendees.map { ["email": $0] }
                // Without this Google records the guests but emails nobody.
                query.append(URLQueryItem(name: "sendUpdates", value: "all"))
            }
            if value.addMeetLink {
                event["conferenceData"] = self.meetConferenceRequest()
                query.append(URLQueryItem(name: "conferenceDataVersion", value: "1"))
            }
            components.queryItems = query.isEmpty ? nil : query
            guard let calendarURL = components.url else { throw AccountWriteError.invalidRequest }
            url = calendarURL
            method = "POST"
            body = try self.jsonData(event)
            contentType = "application/json"
        case let .googleCalendarUpdateEvent(value):
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(value.eventID)")!
            var patch: [String: Any] = [:]
            if let summary = value.summary { patch["summary"] = summary }
            if let description = value.description { patch["description"] = description }
            if let start = value.startRFC3339 { patch["start"] = ["dateTime": start] }
            if let end = value.endRFC3339 { patch["end"] = ["dateTime": end] }
            if let attendees = value.attendees { patch["attendees"] = attendees.map { ["email": $0] } }
            // Guests already on the event are told about every change.
            var query = [URLQueryItem(name: "sendUpdates", value: "all")]
            if value.addMeetLink {
                patch["conferenceData"] = self.meetConferenceRequest()
                query.append(URLQueryItem(name: "conferenceDataVersion", value: "1"))
            }
            components.queryItems = query
            guard let calendarURL = components.url else { throw AccountWriteError.invalidRequest }
            url = calendarURL
            method = "PATCH"
            body = try self.jsonData(patch)
            contentType = "application/json"
        case let .googleDriveCreateTextFile(value):
            var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "uploadType", value: "multipart"),
                URLQueryItem(name: "fields", value: "id"),
            ]
            guard let driveURL = components.url else { throw AccountWriteError.invalidRequest }
            url = driveURL
            method = "POST"
            let boundary = "operator-\(UUID().uuidString.lowercased())"
            let metadata = try self.jsonData(["name": value.name, "mimeType": "text/plain"])
            body = self.multipartRelated(metadata: metadata, content: Data(value.content.utf8), boundary: boundary)
            contentType = "multipart/related; boundary=\(boundary)"
        case let .outlookCreateDraft(value):
            url = URL(string: "https://graph.microsoft.com/v1.0/me/messages")!
            method = "POST"
            body = try self.jsonData([
                "subject": value.subject,
                "body": ["contentType": "Text", "content": value.body],
            ])
            contentType = "application/json"
        case let .outlookSendMail(value):
            url = URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!
            method = "POST"
            body = try self.jsonData([
                "message": [
                    "subject": value.subject,
                    "body": ["contentType": "Text", "content": value.body],
                    "toRecipients": [["emailAddress": ["address": value.to]]],
                ],
                "saveToSentItems": true,
            ])
            contentType = "application/json"
        case let .slackPostMessage(value):
            url = URL(string: "https://slack.com/api/chat.postMessage")!
            method = "POST"
            body = try self.jsonData(["channel": value.channelID, "text": value.text])
            contentType = "application/json"
        case let .spotifyStartPlayback(value):
            var components = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!
            if let deviceID = value.deviceID {
                components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
            }
            guard let spotifyURL = components.url else { throw AccountWriteError.invalidRequest }
            url = spotifyURL
            method = "PUT"
            body = try self.jsonData(["uris": [value.trackURI]])
            contentType = "application/json"
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Google creates the Meet room itself; the request id only makes the
    /// creation idempotent on retry, and this writer never retries.
    private static func meetConferenceRequest() -> [String: Any] {
        ["createRequest": ["requestId": UUID().uuidString.lowercased(), "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
    }

    private static func jsonData(_ object: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw AccountWriteError.invalidRequest
        }
    }

    private static func multipartRelated(metadata: Data, content: Data, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func checkStatus(_ response: HTTPURLResponse, operation: AccountWriteOperation) throws {
        let expected: Int
        switch operation {
        case .googleCalendarCreateEvent, .googleCalendarUpdateEvent, .googleDriveCreateTextFile, .slackPostMessage:
            expected = 200
        case .outlookCreateDraft:
            expected = 201
        case .outlookSendMail:
            expected = 202
        case .spotifyStartPlayback:
            expected = 204
        }
        guard response.statusCode == expected else {
            switch response.statusCode {
            case 401:
                throw AccountWriteError.notConnected
            case 403:
                throw AccountWriteError.permissionDenied
            case 429:
                let parsed = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
                throw AccountWriteError.rateLimited(retryAfterSeconds: min(max(parsed, 1), 86_400))
            default:
                throw AccountWriteError.rejected(statusCode: response.statusCode)
            }
        }
    }

    private static func receipt(for input: AccountWriteRequest, data: Data) throws -> AccountWriteReceipt {
        switch input {
        case .googleCalendarCreateEvent, .googleCalendarUpdateEvent:
            let object = try self.responseObject(data)
            guard let id = object["id"] as? String, self.validRemoteID(id, maxBytes: 1_024) else {
                throw AccountWriteError.invalidResponse
            }
            // Only a Meet URL is passed on; anything else in hangoutLink is dropped.
            let link = (object["hangoutLink"] as? String).flatMap { self.matches($0, pattern: #"^https://meet\.google\.com/[A-Za-z0-9-]{1,64}$"#) ? $0 : nil }
            return .googleCalendarEvent(id: id, meetLink: link)
        case .googleDriveCreateTextFile:
            let object = try self.responseObject(data)
            guard let id = object["id"] as? String, self.validRemoteID(id, maxBytes: 2_048) else {
                throw AccountWriteError.invalidResponse
            }
            return .googleDriveFile(id: id)
        case .outlookCreateDraft:
            let object = try self.responseObject(data)
            guard let id = object["id"] as? String, self.validRemoteID(id, maxBytes: 2_048) else {
                throw AccountWriteError.invalidResponse
            }
            return .outlookDraft(id: id)
        case .outlookSendMail:
            guard data.isEmpty else { throw AccountWriteError.invalidResponse }
            return .outlookMailAccepted
        case .slackPostMessage:
            let object = try self.responseObject(data)
            guard object["ok"] as? Bool == true,
                  let channel = object["channel"] as? String,
                  self.matches(channel, pattern: #"^[CDG][A-Z0-9]{1,99}$"#),
                  let timestamp = object["ts"] as? String,
                  self.matches(timestamp, pattern: #"^[0-9]{1,20}\.[0-9]{1,12}$"#)
            else { throw AccountWriteError.invalidResponse }
            return .slackMessage(channelID: channel, timestamp: timestamp)
        case .spotifyStartPlayback:
            guard data.isEmpty else { throw AccountWriteError.invalidResponse }
            return .spotifyPlaybackStarted
        }
    }

    private static func responseObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object.count <= 64 else {
            throw AccountWriteError.invalidResponse
        }
        return object
    }

    private static func validRemoteID(_ value: String, maxBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maxBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func receiptFieldCount(_ receipt: AccountWriteReceipt) -> Int {
        switch receipt {
        case .googleCalendarEvent, .googleDriveFile, .outlookDraft:
            1
        case .outlookMailAccepted, .spotifyPlaybackStarted:
            0
        case .slackMessage:
            2
        }
    }
}
