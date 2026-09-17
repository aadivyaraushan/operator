import Foundation
import OSLog

/// A course the person is enrolled in, with the grade Canvas shows them.
struct CanvasCourse: Equatable, Sendable {
    let id: Int
    let name: String
    let code: String
    let term: String?
    /// Canvas's computed current score (0 to 100) and letter, when the
    /// course lets students see them. Nil otherwise, which is common.
    let currentScore: Double?
    let currentGrade: String?
}

/// One thing with a date in a course: an assignment, quiz, discussion,
/// event or note, as the planner lists it. Submission state is Canvas's
/// own: submitted, missing (past due, nothing handed in), late.
struct CanvasPlannerItem: Equatable, Sendable {
    let kind: String
    let title: String
    let course: String?
    let courseID: Int?
    let dueAtRFC3339: String?
    let pointsPossible: Double?
    let submitted: Bool?
    let missing: Bool?
    let late: Bool?
    let link: String?
}

struct CanvasMissingSubmission: Equatable, Sendable {
    let title: String
    let courseID: Int?
    let dueAtRFC3339: String?
    let pointsPossible: Double?
    let link: String?
}

struct CanvasAnnouncement: Equatable, Sendable {
    let id: Int
    let courseID: Int?
    let title: String
    let text: String
    let author: String?
    let postedAtRFC3339: String?
    let link: String?
}

enum CanvasClientError: Error, Equatable, Sendable {
    /// No address or token saved, or Canvas answered 401: the token is
    /// wrong, expired or deleted.
    case notConnected
    /// 403 or 404: not enrolled, or the course hides this.
    case notVisible
    /// 429; Canvas asked for a pause. Never retried here.
    case rateLimited(retryAfterSeconds: Int)
    case invalidResponse
    case unavailable
}

/// How a read is signed: an access token the person made (or Operator made
/// for them), or the browser session from signing in inside Operator, for
/// schools that do not let students make tokens. Canvas's API takes either;
/// with a session it prefixes JSON with `while(1);`, which is stripped.
enum CanvasCredentials: Equatable, Sendable {
    case token(String)
    case session(cookies: [HTTPCookie])
}

/// Canvas's REST API with the person's own credentials, the way Canvas
/// documents it: `Authorization: Bearer` or the signed-in session,
/// `https://<school>/api/v1`, pages linked by the `Link` header. GETs only.
/// Every read is bounded in pages and bytes so a large school cannot
/// overrun the reply.
actor CanvasClient {
    static let maxBodyBytes = 2_097_152
    static let pageSize = 50
    static let maxPages = 4
    static let textLimit = 2_000

    private let transport: any PhoneHTTPTransport
    private let baseURL: @Sendable () -> URL?
    private let credentials: @Sendable () async throws -> CanvasCredentials?
    private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-client")

    init(
        transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport(),
        baseURL: @escaping @Sendable () -> URL?,
        credentials: @escaping @Sendable () async throws -> CanvasCredentials?)
    {
        self.transport = transport
        self.baseURL = baseURL
        self.credentials = credentials
    }

    /// A token-only client, for setup and tests.
    init(
        transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport(),
        baseURL: @escaping @Sendable () -> URL?,
        token: @escaping @Sendable () async throws -> String?)
    {
        self.init(transport: transport, baseURL: baseURL, credentials: {
            try await token().map { CanvasCredentials.token($0) }
        })
    }

    /// The signed-in person's name. Once, when a token is saved, to prove
    /// the address and token go together.
    func me() async throws -> String {
        let object = try await self.getObject(path: "/users/self")
        guard let name = (object["name"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            ?? (object["short_name"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
        else { throw CanvasClientError.invalidResponse }
        return String(name.prefix(100))
    }

    /// Active enrollments, with the grade Canvas includes when asked for
    /// total scores. Concluded courses are left out.
    func courses() async throws -> [CanvasCourse] {
        let objects = try await self.getPages(path: "/courses", query: [
            ("enrollment_state", "active"), ("include[]", "term"), ("include[]", "total_scores"),
        ])
        return objects.compactMap(Self.course(from:))
    }

    /// The planner between two instants, as Canvas orders it.
    func plannerItems(from start: Date, to end: Date) async throws -> [CanvasPlannerItem] {
        let objects = try await self.getPages(path: "/planner/items", query: [
            ("start_date", Self.rfc3339(start)), ("end_date", Self.rfc3339(end)),
        ])
        return objects.compactMap(Self.plannerItem(from:))
    }

    /// Past due with nothing handed in, across all courses.
    func missingSubmissions() async throws -> [CanvasMissingSubmission] {
        let objects = try await self.getPages(path: "/users/self/missing_submissions", query: [("include[]", "course")])
        return objects.compactMap(Self.missingSubmission(from:))
    }

    /// Announcements in the given courses since `start`, newest first as
    /// Canvas returns them. The bodies are HTML and are reduced to text.
    func announcements(courseIDs: [Int], since start: Date) async throws -> [CanvasAnnouncement] {
        guard !courseIDs.isEmpty else { return [] }
        var query: [(String, String)] = courseIDs.prefix(20).map { ("context_codes[]", "course_\($0)") }
        query.append(("start_date", Self.rfc3339(start)))
        let objects = try await self.getPages(path: "/announcements", query: query)
        return objects.compactMap(Self.announcement(from:))
    }

    // MARK: Wire

    static func course(from object: [String: Any]) -> CanvasCourse? {
        guard let id = Self.int(object["id"]), let name = object["name"] as? String, !name.isEmpty else { return nil }
        let enrollment = (object["enrollments"] as? [[String: Any]])?.first { ($0["type"] as? String) == "student" }
            ?? (object["enrollments"] as? [[String: Any]])?.first
        return CanvasCourse(
            id: id, name: String(name.prefix(200)),
            code: String(((object["course_code"] as? String) ?? "").prefix(80)),
            term: ((object["term"] as? [String: Any])?["name"] as? String).map { String($0.prefix(80)) },
            currentScore: Self.double(enrollment?["computed_current_score"]),
            currentGrade: (enrollment?["computed_current_grade"] as? String).map { String($0.prefix(16)) })
    }

    static func plannerItem(from object: [String: Any]) -> CanvasPlannerItem? {
        guard let kind = object["plannable_type"] as? String else { return nil }
        let plannable = object["plannable"] as? [String: Any] ?? [:]
        let title = (plannable["title"] as? String) ?? (plannable["name"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let submissions = object["submissions"] as? [String: Any]
        return CanvasPlannerItem(
            kind: String(kind.prefix(40)), title: String(title.prefix(200)),
            course: (object["context_name"] as? String).map { String($0.prefix(120)) },
            courseID: Self.int(object["course_id"]),
            dueAtRFC3339: (plannable["due_at"] as? String) ?? (object["plannable_date"] as? String),
            pointsPossible: Self.double(plannable["points_possible"]),
            submitted: submissions?["submitted"] as? Bool,
            missing: submissions?["missing"] as? Bool,
            late: submissions?["late"] as? Bool,
            link: Self.link(object["html_url"]))
    }

    static func missingSubmission(from object: [String: Any]) -> CanvasMissingSubmission? {
        guard let title = object["name"] as? String, !title.isEmpty else { return nil }
        return CanvasMissingSubmission(
            title: String(title.prefix(200)), courseID: Self.int(object["course_id"]),
            dueAtRFC3339: object["due_at"] as? String, pointsPossible: Self.double(object["points_possible"]),
            link: Self.link(object["html_url"]))
    }

    static func announcement(from object: [String: Any]) -> CanvasAnnouncement? {
        guard let id = Self.int(object["id"]), let title = object["title"] as? String else { return nil }
        let context = object["context_code"] as? String ?? ""
        let courseID = context.hasPrefix("course_") ? Int(context.dropFirst("course_".count)) : nil
        return CanvasAnnouncement(
            id: id, courseID: courseID, title: String(title.prefix(200)),
            text: Self.plainText(object["message"] as? String ?? ""),
            author: ((object["author"] as? [String: Any])?["display_name"] as? String).map { String($0.prefix(80)) },
            postedAtRFC3339: object["posted_at"] as? String,
            link: Self.link(object["html_url"]))
    }

    /// Canvas bodies are HTML. Tags go, entities are decoded for the few
    /// that matter, whitespace collapses, and the result is bounded.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</li>|</h[1-6]>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, plain) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(Self.textLimit))
    }

    private static func link(_ value: Any?) -> String? {
        guard let text = value as? String, let url = URL(string: text), url.scheme == "https" else { return nil }
        return String(text.prefix(512))
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Follows `Link: <…>; rel="next"` up to the page cap. Every page is
    /// checked against the school's own host; a next link elsewhere ends
    /// the read rather than being followed.
    private func getPages(path: String, query: [(String, String)]) async throws -> [[String: Any]] {
        guard let base = self.baseURL() else { throw CanvasClientError.notConnected }
        var components = URLComponents(url: base.appendingPathComponent("api/v1" + path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } + [URLQueryItem(name: "per_page", value: String(Self.pageSize))]
        guard var url = components?.url else { throw CanvasClientError.invalidResponse }
        var all: [[String: Any]] = []
        for _ in 0..<Self.maxPages {
            let (data, http) = try await self.get(url)
            guard let page = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw CanvasClientError.invalidResponse }
            all.append(contentsOf: page)
            guard let next = Self.nextLink(in: http.value(forHTTPHeaderField: "Link")), next.host == base.host else { break }
            url = next
        }
        return all
    }

    private func getObject(path: String) async throws -> [String: Any] {
        guard let base = self.baseURL() else { throw CanvasClientError.notConnected }
        let (data, _) = try await self.get(base.appendingPathComponent("api/v1" + path))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CanvasClientError.invalidResponse }
        return object
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch try await self.credentials() {
        case let .token(token):
            guard Self.plausibleToken(token) else { throw CanvasClientError.notConnected }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .session(cookies):
            // Only the school's own cookies, only over https, and only the
            // Cookie header: the session is never sent anywhere else.
            let mine = cookies.filter { cookie in Self.cookie(cookie, matches: url) }
            guard !mine.isEmpty, let header = HTTPCookie.requestHeaderFields(with: mine)["Cookie"] else { throw CanvasClientError.notConnected }
            request.setValue(header, forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = false
        case nil:
            throw CanvasClientError.notConnected
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await self.transport.data(for: request) } catch { throw CanvasClientError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw CanvasClientError.unavailable }
        self.logger.info("[canvas-client] response route=\(Self.route(url.path), privacy: .public) status=\(http.statusCode) bytes=\(data.count)")
        switch http.statusCode {
        case 200: break
        case 401: throw CanvasClientError.notConnected
        case 403, 404: throw CanvasClientError.notVisible
        case 429:
            let header = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw CanvasClientError.rateLimited(retryAfterSeconds: Int(min(max(header, 1), 86_400).rounded(.up)))
        default: throw CanvasClientError.unavailable
        }
        guard data.count <= Self.maxBodyBytes else { throw CanvasClientError.invalidResponse }
        return (Self.stripSessionPrefix(data), http)
    }

    /// Session-authenticated JSON comes back as `while(1);[...]`, Canvas's
    /// guard against JSON hijacking in a browser. It is not JSON until the
    /// prefix is gone.
    static func stripSessionPrefix(_ data: Data) -> Data {
        let prefix = Data("while(1);".utf8)
        guard data.count > prefix.count, data.prefix(prefix.count) == prefix else { return data }
        return data.dropFirst(prefix.count)
    }

    static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        return !cookie.isSecure || url.scheme == "https"
    }

    static func nextLink(in header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") {
            let pieces = part.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0 == "rel=\"next\"" }),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">")
            else { continue }
            return URL(string: String(pieces[0].dropFirst().dropLast()))
        }
        return nil
    }

    /// Logged instead of the path, so course ids never reach the log.
    private static func route(_ path: String) -> String {
        if path.hasSuffix("/users/self") { return "me" }
        if path.contains("/missing_submissions") { return "missing" }
        if path.contains("/planner/items") { return "planner" }
        if path.contains("/announcements") { return "announcements" }
        if path.contains("/courses") { return "courses" }
        return "other"
    }

    static func plausibleToken(_ token: String) -> Bool {
        (20...400).contains(token.utf8.count) && !token.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    /// "canvas.illinois.edu", "https://canvas.illinois.edu/" or a deeper
    /// page all become the https origin. Anything that is not https on a
    /// host with a dot is refused.
    static func baseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 253 + 8 + 512 else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), host.contains("."), components.port == nil,
              host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: "https://\(host)")
    }
}
