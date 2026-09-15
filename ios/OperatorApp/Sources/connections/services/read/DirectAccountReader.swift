import Foundation
import OSLog

enum AccountReadOperation: String, Sendable {
    case googleCalendarEvents, googleDriveFiles, gmailMessages, googleTasks, outlookInbox,
         outlookCalendarEvents, slackChannels, slackHistory, spotifySearch, spotifyPlayback
    var provider: OAuthProvider {
        switch self {
        case .googleCalendarEvents, .googleDriveFiles, .gmailMessages, .googleTasks: .google
        case .outlookInbox, .outlookCalendarEvents: .microsoftOutlook
        case .slackChannels, .slackHistory: .slack
        case .spotifySearch, .spotifyPlayback: .spotify
        }
    }
}

struct AccountReadRequest: Sendable {
    let operation: AccountReadOperation; let query: String?; let channel: String?; let timeMin: String?; let timeMax: String?; let limit: Int; let cursor: String?
}

struct AccountReadPage: Sendable {
    let payloadJSON: String; let count: Int; let nextCursor: String?
}

enum AccountReadError: Error, Equatable, Sendable { case invalidRequest, notConnected, permissionDenied, rateLimited(retryAfterSeconds: Int), unavailable, invalidResponse }

actor DirectAccountReader {
    private let transport: any PhoneHTTPTransport
    private let bearer: @Sendable (OAuthProvider) async throws -> String
    private let logger = Logger(subsystem: "app.operator.ios", category: "account-read")

    init(transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport(), bearer: @escaping @Sendable (OAuthProvider) async throws -> String) {
        self.transport = transport; self.bearer = bearer
    }

    func read(_ input: AccountReadRequest) async throws -> AccountReadPage {
        guard self.valid(input) else { throw AccountReadError.invalidRequest }
        // Gmail is the one operation a single request cannot answer, so it
        // has its own path. See gmailPage.
        self.logger.info("[account-read] request provider=\(input.operation.provider.rawValue, privacy: .public) operation=\(input.operation.rawValue, privacy: .public) limit=\(input.limit)")
        if input.operation == .gmailMessages { return try await self.gmailPage(input) }
        let url = try self.url(for: input)
        let token: String
        do { token = try await self.bearer(input.operation.provider) } catch { throw AccountReadError.notConnected }
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data; let response: URLResponse
        do { (data, response) = try await self.transport.data(for: request) } catch { throw AccountReadError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw AccountReadError.unavailable }
        self.logger.info("[account-read] response provider=\(input.operation.provider.rawValue, privacy: .public) operation=\(input.operation.rawValue, privacy: .public) status=\(http.statusCode) response_bytes=\(data.count)")
        guard data.count <= 512_000 else { throw AccountReadError.invalidResponse }
        if input.operation == .spotifyPlayback, http.statusCode == 204 { return .init(payloadJSON: "[]", count: 0, nextCursor: nil) }
        switch http.statusCode { case 200: break; case 401: throw AccountReadError.notConnected; case 403: throw AccountReadError.permissionDenied; case 429: throw AccountReadError.rateLimited(retryAfterSeconds: max(1, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1)); case 500...599: throw AccountReadError.unavailable; default: throw AccountReadError.unavailable }
        return try self.page(data, input: input)
    }

    private func valid(_ r: AccountReadRequest) -> Bool {
        guard (1...20).contains(r.limit), (r.query?.count ?? 0) <= 200, (r.channel?.count ?? 0) <= 100, (r.cursor?.count ?? 0) <= 500 else { return false }
        if (r.operation == .spotifySearch || r.operation == .spotifyPlayback) && r.limit > 10 { return false }
        if let cursor = r.cursor, cursor.contains("://") { return false }
        switch r.operation {
        case .googleCalendarEvents, .outlookCalendarEvents:
            guard let minText = r.timeMin, let maxText = r.timeMax, r.channel == nil,
                  let min = Self.rfc3339(minText), let max = Self.rfc3339(maxText) else { return false }
            return min < max
        case .googleDriveFiles: return !(r.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && r.channel == nil
        case .googleTasks:
            guard r.query == nil, r.timeMin == nil, r.timeMax == nil else { return false }
            // The task list id lands in the URL path, so it is checked here
            // and percent-encoded there. Absent means the default list.
            if let list = r.channel, !Self.isSafePathSegment(list) { return false }
            return true
        case .gmailMessages:
            guard r.channel == nil, r.timeMin == nil, r.timeMax == nil else { return false }
            guard r.limit <= Self.gmailMaximumLimit else { return false }
            if let query = r.query, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            return true
        case .spotifySearch:
            guard !(r.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), r.channel == nil else { return false }
            guard let cursor = r.cursor else { return true }
            guard let value = Int(cursor) else { return false }
            return value >= 0
        case .slackHistory: return !(r.channel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .slackChannels, .outlookInbox: return r.channel == nil
        case .spotifyPlayback:
            guard r.channel == nil else { return false }
            guard let cursor = r.cursor else { return true }
            guard let value = Int(cursor) else { return false }
            return value >= 0
        }
    }

    /// The most Gmail messages one call may return. Lower than the shared
    /// limit on purpose: unlike every other operation here, each row costs a
    /// request of its own.
    static let gmailMaximumLimit = 10

    /// Gmail is the one operation a single request cannot answer.
    /// users.messages.list returns nothing but ids, and there is no list
    /// endpoint that carries a subject or a sender, so a useful read is one
    /// list call plus one metadata call per id. The metadata calls overlap:
    /// this is an actor, and an actor releases at every await, so the child
    /// tasks below genuinely interleave rather than queueing.
    ///
    /// Order is restored explicitly afterwards. Gmail returns newest first
    /// and the whole value of the read is that ordering, which a task group
    /// does not preserve on its own.
    private func gmailPage(_ input: AccountReadRequest) async throws -> AccountReadPage {
        let listData = try await self.fetch(try self.url(for: input), provider: .google)
        guard let listObject = try? JSONSerialization.jsonObject(with: listData) as? [String: Any] else {
            throw AccountReadError.invalidResponse
        }
        // Gmail omits "messages" entirely when nothing matches, which is an
        // empty result and not a malformed one.
        let rawMessages = listObject["messages"] as? [Any] ?? []
        guard rawMessages.count <= input.limit else { throw AccountReadError.invalidResponse }
        let ids = rawMessages.compactMap { ($0 as? [String: Any])?["id"] as? String }
        guard ids.count == rawMessages.count else { throw AccountReadError.invalidResponse }

        // The child tasks carry Data, not a parsed row: [String: Any] is not
        // Sendable and cannot cross a task-group boundary under Swift 6.
        // Parsing happens after collection, on the way to building rows.
        var fetched: [(Int, Data)] = []
        if !ids.isEmpty {
            fetched = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (offset, id) in ids.enumerated() {
                    group.addTask {
                        (offset, try await self.fetch(try Self.metadataURL(id: id), provider: .google))
                    }
                }
                var collected: [(Int, Data)] = []
                for try await item in group { collected.append(item) }
                return collected
            }
        }
        let ordered = try fetched.sorted { $0.0 < $1.0 }.map { try Self.gmailRow($0.1) }
        guard let encoded = try? JSONSerialization.data(withJSONObject: ordered, options: [.sortedKeys]),
              encoded.count <= 256_000
        else { throw AccountReadError.invalidResponse }
        let next = listObject["nextPageToken"] as? String
        return .init(
            payloadJSON: String(decoding: encoded, as: UTF8.self),
            count: ordered.count,
            nextCursor: next?.isEmpty == true ? nil : next)
    }

    private static func metadataURL(id: String) throws -> URL {
        // The id came from Gmail's own list response and is placed in the
        // path, so it is percent-encoded rather than interpolated raw.
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !escaped.isEmpty, escaped.count <= 256
        else { throw AccountReadError.invalidResponse }
        var components = URLComponents(string: "https://gmail.googleapis.com")!
        components.path = "/gmail/v1/users/me/messages/\(escaped)"
        components.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Date"),
        ]
        guard let url = components.url else { throw AccountReadError.invalidResponse }
        return url
    }

    /// Builds a row field by field. Nothing is copied across from the
    /// response wholesale, so the shape of what reaches the agent is fixed
    /// here rather than filtered downstream. format=metadata already means
    /// Gmail never sends a body; snippet is its own truncated preview and is
    /// the only message content included.
    private static func gmailRow(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String
        else { throw AccountReadError.invalidResponse }
        let headers = ((object["payload"] as? [String: Any])?["headers"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
        func header(_ name: String) -> String? {
            headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String
        }
        var row: [String: Any] = ["id": id]
        if let threadID = object["threadId"] as? String { row["threadId"] = threadID }
        if let snippet = object["snippet"] as? String { row["snippet"] = snippet }
        if let subject = header("Subject") { row["subject"] = subject }
        if let from = header("From") { row["from"] = from }
        if let date = header("Date") { row["date"] = date }
        return row
    }

    /// One authenticated GET, with the same status mapping the single-request
    /// path applies inline.
    private func fetch(_ url: URL, provider: OAuthProvider) async throws -> Data {
        let token: String
        do { token = try await self.bearer(provider) } catch { throw AccountReadError.notConnected }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await self.transport.data(for: request) } catch { throw AccountReadError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw AccountReadError.unavailable }
        self.logger.info("[account-read] response provider=\(provider.rawValue, privacy: .public) operation=gmailMessages status=\(http.statusCode) response_bytes=\(data.count)")
        guard data.count <= 512_000 else { throw AccountReadError.invalidResponse }
        switch http.statusCode {
        case 200: return data
        case 401: throw AccountReadError.notConnected
        case 403: throw AccountReadError.permissionDenied
        case 429: throw AccountReadError.rateLimited(
            retryAfterSeconds: max(1, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1))
        default: throw AccountReadError.unavailable
        }
    }

    /// A value that is about to be placed in a URL path rather than a query.
    /// Checked before use rather than trusted, because a path segment that
    /// escapes its position changes which endpoint is called. The leading "@"
    /// is allowed for aliases such as Tasks' "@default".
    static func isSafePathSegment(_ value: String) -> Bool {
        guard (1 ... 128).contains(value.count) else { return false }
        var rest = Substring(value)
        if rest.hasPrefix("@") { rest = rest.dropFirst() }
        guard !rest.isEmpty else { return false }
        return rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    private static let pathSegmentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._@"))

    private static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? ""
    }

    private func url(for r: AccountReadRequest) throws -> URL {
        let base: String; var path: String; var items: [URLQueryItem] = []
        switch r.operation {
        case .googleCalendarEvents:
            base = "https://www.googleapis.com"; path = "/calendar/v3/calendars/primary/events"; items = [.init(name:"singleEvents",value:"true"),.init(name:"orderBy",value:"startTime"),.init(name:"timeMin",value:r.timeMin),.init(name:"timeMax",value:r.timeMax),.init(name:"maxResults",value:String(r.limit))]; if let q=r.query { items.append(.init(name:"q",value:q)) }; if let c=r.cursor { items.append(.init(name:"pageToken",value:c)) }
        case .googleDriveFiles:
            base = "https://www.googleapis.com"; path = "/drive/v3/files"; let safe = r.query!.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"'",with:"\\'"); items=[.init(name:"q",value:"name contains '\(safe)' and trashed = false"),.init(name:"spaces",value:"drive"),.init(name:"pageSize",value:String(r.limit)),.init(name:"fields",value:"nextPageToken,files(id,name,mimeType)")]; if let c=r.cursor { items.append(.init(name:"pageToken",value:c)) }
        case .gmailMessages:
            base = "https://gmail.googleapis.com"; path = "/gmail/v1/users/me/messages"; items=[.init(name:"maxResults",value:String(r.limit))]; if let q=r.query { items.append(.init(name:"q",value:q)) }; if let c=r.cursor { items.append(.init(name:"pageToken",value:c)) }
        case .googleTasks:
            base = "https://tasks.googleapis.com"; path = "/tasks/v1/lists/\(Self.pathSegment(r.channel ?? "@default"))/tasks"; items=[.init(name:"maxResults",value:String(r.limit)),.init(name:"showCompleted",value:"false"),.init(name:"showDeleted",value:"false"),.init(name:"showHidden",value:"false")]; if let c=r.cursor { items.append(.init(name:"pageToken",value:c)) }
        case .outlookInbox:
            base = "https://graph.microsoft.com"; path = "/v1.0/me/mailFolders/inbox/messages"; items=[.init(name:"$top",value:String(r.limit)),.init(name:"$select",value:"id,subject,from,receivedDateTime,bodyPreview")]; if let c=r.cursor { items.append(.init(name:"$skip",value:c)) }
        case .outlookCalendarEvents:
            base = "https://graph.microsoft.com"; path = "/v1.0/me/calendarView"; items=[.init(name:"startDateTime",value:r.timeMin),.init(name:"endDateTime",value:r.timeMax),.init(name:"$top",value:String(r.limit)),.init(name:"$orderby",value:"start/dateTime"),.init(name:"$select",value:"id,subject,start,end,location,isAllDay,webLink,organizer")]; if let c=r.cursor { items.append(.init(name:"$skip",value:c)) }
        case .slackChannels:
            base="https://slack.com"; path="/api/conversations.list"; items=[.init(name:"exclude_archived",value:"true"),.init(name:"types",value:"public_channel,private_channel"),.init(name:"limit",value:String(r.limit))]; if let c=r.cursor { items.append(.init(name:"cursor",value:c)) }
        case .slackHistory:
            base="https://slack.com"; path="/api/conversations.history"; items=[.init(name:"channel",value:r.channel),.init(name:"limit",value:String(r.limit))]; if let c=r.cursor { items.append(.init(name:"cursor",value:c)) }
        case .spotifySearch:
            base="https://api.spotify.com"; path="/v1/search"; items=[.init(name:"q",value:r.query),.init(name:"type",value:"track"),.init(name:"limit",value:String(r.limit)),.init(name:"offset",value:r.cursor ?? "0")]
        case .spotifyPlayback:
            base="https://api.spotify.com"; path="/v1/me/player"; items=[]
        }
        var c=URLComponents(string:base)!; c.path=path; c.queryItems=items; guard let url=c.url else { throw AccountReadError.invalidRequest }; return url
    }

    private func page(_ data: Data, input: AccountReadRequest) throws -> AccountReadPage {
        guard let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw AccountReadError.invalidResponse }
        if input.operation == .slackChannels || input.operation == .slackHistory { guard object["ok"] as? Bool == true else { throw AccountReadError.unavailable } }
        let array: [Any]?; let next: String?
        switch input.operation {
        case .googleCalendarEvents: array=object["items"] as? [Any]; next=object["nextPageToken"] as? String
        case .googleDriveFiles: array=object["files"] as? [Any]; next=object["nextPageToken"] as? String
        // Tasks omits items entirely when the list is empty, which is an
        // empty result rather than a malformed one.
        case .googleTasks: array=(object["items"] as? [Any]) ?? []; next=object["nextPageToken"] as? String
        // Unreachable: read() routes .gmailMessages to gmailPage before here.
        case .gmailMessages: throw AccountReadError.invalidResponse
        case .outlookInbox:
            array=object["value"] as? [Any]; next=try self.microsoftCursor(object["@odata.nextLink"] as? String, path:"/v1.0/me/mailFolders/inbox/messages")
        case .outlookCalendarEvents:
            array=object["value"] as? [Any]; next=try self.microsoftCursor(object["@odata.nextLink"] as? String, path:"/v1.0/me/calendarView")
        case .slackChannels: array=object["channels"] as? [Any]; next=((object["response_metadata"] as? [String:Any])?["next_cursor"] as? String)
        case .slackHistory: array=object["messages"] as? [Any]; next=((object["response_metadata"] as? [String:Any])?["next_cursor"] as? String)
        case .spotifySearch: let tracks=object["tracks"] as? [String:Any]; array=tracks?["items"] as? [Any]; let offset=tracks?["offset"] as? Int ?? 0; next=(tracks?["next"] as? String) == nil ? nil : String(offset + input.limit)
        case .spotifyPlayback: array = object.isEmpty ? nil : [object]; next=nil
        }
        guard let array, array.count <= input.limit else { throw AccountReadError.invalidResponse }
        let safe = array.compactMap { self.sanitize($0, operation: input.operation) }
        guard safe.count == array.count, let encoded = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), encoded.count <= 256_000 else { throw AccountReadError.invalidResponse }
        return .init(payloadJSON:String(decoding: encoded, as: UTF8.self),count:safe.count,nextCursor:next?.isEmpty == true ? nil : next)
    }

    private func microsoftCursor(_ link: String?, path: String) throws -> String? {
        guard let link else { return nil }; guard let url=URL(string:link), url.scheme=="https", url.host=="graph.microsoft.com", url.path==path, let skip=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="$skip"})?.value, let value = Int(skip), value >= 0 else { throw AccountReadError.invalidResponse }; return String(value)
    }

    private static func rfc3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? { formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value) }()
    }

    private func sanitize(_ value: Any, operation: AccountReadOperation) -> [String: Any]? {
        guard let object = value as? [String: Any] else { return nil }
        let keys: Set<String>
        switch operation {
        // attendees is returned so an update that changes the guest list can
        // carry the existing guests; the PATCH replaces the whole list.
        case .googleCalendarEvents: keys = ["id", "summary", "description", "start", "end", "htmlLink", "attendees", "hangoutLink"]
        case .googleDriveFiles: keys = ["id", "name", "mimeType"]
        case .googleTasks: keys = ["id", "title", "notes", "due", "status", "updated", "webViewLink"]
        // Unreachable for the same reason; Gmail rows are constructed field
        // by field in gmailRow rather than filtered from a response.
        case .gmailMessages: keys = []
        case .outlookInbox: keys = ["id", "subject", "from", "receivedDateTime", "bodyPreview"]
        case .outlookCalendarEvents: keys = ["id", "subject", "start", "end", "location", "isAllDay", "webLink", "organizer"]
        case .slackChannels: keys = ["id", "name", "is_private", "is_archived", "topic", "purpose"]
        case .slackHistory: keys = ["ts", "user", "text", "thread_ts"]
        case .spotifySearch: keys = ["id", "name", "artists", "album", "duration_ms", "external_urls"]
        case .spotifyPlayback: keys = ["device", "item", "is_playing", "progress_ms", "timestamp"]
        }
        var result: [String: Any] = [:]
        for key in keys { if let item = object[key], Self.safeJSON(item) { result[key] = item } }
        return result
    }

    private static func safeJSON(_ value: Any) -> Bool {
        if let string = value as? String { return string.utf8.count <= 8_192 }
        if value is NSNull || value is NSNumber { return true }
        if let array = value as? [Any] { return array.count <= 100 && array.allSatisfy(safeJSON) }
        if let object = value as? [String: Any] { return object.count <= 50 && object.allSatisfy { $0.key.utf8.count <= 128 && safeJSON($0.value) } }
        return false
    }
}
