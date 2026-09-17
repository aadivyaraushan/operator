import Foundation
import OperatorCore
import OSLog

/// The three Canvas reads: `canvas.courses`, `canvas.upcoming` and
/// `canvas.announcements`, through the person's own access token. Reads
/// only; every payload says so and says what the person can do next.
@MainActor
final class ForegroundCanvasService: GatewayNodeCommandHandler {
    static let coursesCommand = "canvas.courses"
    static let upcomingCommand = "canvas.upcoming"
    static let announcementsCommand = "canvas.announcements"
    static let commands = [coursesCommand, upcomingCommand, announcementsCommand]
    static let defaultUpcomingDays = 7
    static let defaultAnnouncementDays = 14
    static let defaultAnnouncementLimit = 20
    static let maxPayloadBytes = 262_144

    private let client: CanvasClient
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-read")

    init(client: CanvasClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult {
        guard Self.commands.contains(command) else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let object = Self.parameters(from: paramsJSON) else {
            return .failure(code: "INVALID_REQUEST", message: "\(command) takes a small JSON object of the documented parameters and nothing else")
        }
        self.logger.info("[canvas-read] input command=\(command, privacy: .public)")
        do {
            let payload: [String: Any] = switch command {
            case Self.coursesCommand: try await self.courses(object)
            case Self.upcomingCommand: try await self.upcoming(object)
            default: try await self.announcements(object)
            }
            return Self.encode(payload)
        } catch let error as CanvasClientError {
            self.logger.info("[canvas-read] refused command=\(command, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return Self.failure(for: error)
        } catch let error as ParameterError {
            return .failure(code: "INVALID_REQUEST", message: error.message)
        } catch {
            return .failure(code: "UNAVAILABLE", message: "Canvas could not be read right now.")
        }
    }

    private func courses(_ object: [String: Any]) async throws -> [String: Any] {
        guard object.isEmpty else { throw ParameterError("canvas.courses takes no parameters") }
        let courses = try await self.client.courses()
        self.logger.info("[canvas-read] courses count=\(courses.count)")
        return [
            "courses": courses.map { course -> [String: Any] in
                var item: [String: Any] = ["id": course.id, "name": course.name, "code": course.code]
                if let term = course.term { item["term"] = term }
                if let score = course.currentScore { item["currentScore"] = score }
                if let grade = course.currentGrade { item["currentGrade"] = grade }
                return item
            },
            "readAt": CanvasClient.rfc3339(self.now()),
            "nextStep": "A course without currentScore does not show students a grade in Canvas; say so rather than guessing. Use a course's id for canvas.announcements. Read-only.",
        ]
    }

    private func upcoming(_ object: [String: Any]) async throws -> [String: Any] {
        guard Set(object.keys).isSubset(of: ["days"]) else { throw ParameterError("canvas.upcoming takes only days (1 to 30)") }
        let days = try Self.integer(object["days"], name: "days", range: 1...30, default: Self.defaultUpcomingDays)
        let start = self.now()
        let end = start.addingTimeInterval(TimeInterval(days) * 86_400)
        let items = try await self.client.plannerItems(from: start, to: end)
        let missing = (try? await self.client.missingSubmissions()) ?? []
        self.logger.info("[canvas-read] upcoming days=\(days) items=\(items.count) missing=\(missing.count)")
        let sorted = items.sorted { (CanvasClient.date($0.dueAtRFC3339) ?? .distantFuture) < (CanvasClient.date($1.dueAtRFC3339) ?? .distantFuture) }
        return [
            "from": CanvasClient.rfc3339(start),
            "to": CanvasClient.rfc3339(end),
            "items": sorted.map { item -> [String: Any] in
                var out: [String: Any] = ["kind": item.kind, "title": item.title]
                if let course = item.course { out["course"] = course }
                if let courseID = item.courseID { out["courseID"] = courseID }
                if let due = item.dueAtRFC3339 { out["dueAt"] = due }
                if let points = item.pointsPossible { out["points"] = points }
                if let submitted = item.submitted { out["submitted"] = submitted }
                if let missing = item.missing { out["missing"] = missing }
                if let late = item.late { out["late"] = late }
                if let link = item.link { out["link"] = link }
                return out
            },
            "missing": missing.map { item -> [String: Any] in
                var out: [String: Any] = ["title": item.title]
                if let courseID = item.courseID { out["courseID"] = courseID }
                if let due = item.dueAtRFC3339 { out["dueAt"] = due }
                if let points = item.pointsPossible { out["points"] = points }
                if let link = item.link { out["link"] = link }
                return out
            },
            "readAt": CanvasClient.rfc3339(start),
            "nextStep": "List what is due soonest first with the course and time in the person's own words; say which are already submitted. Anything in missing is past due with nothing handed in. Read-only: nothing can be submitted from here.",
        ]
    }

    private func announcements(_ object: [String: Any]) async throws -> [String: Any] {
        guard Set(object.keys).isSubset(of: ["days", "limit"]) else { throw ParameterError("canvas.announcements takes only days (1 to 60) and limit (1 to 50)") }
        let days = try Self.integer(object["days"], name: "days", range: 1...60, default: Self.defaultAnnouncementDays)
        let limit = try Self.integer(object["limit"], name: "limit", range: 1...50, default: Self.defaultAnnouncementLimit)
        let current = self.now()
        let courses = try await self.client.courses()
        let names = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0.name) })
        let announcements = try await self.client.announcements(courseIDs: courses.map(\.id), since: current.addingTimeInterval(-TimeInterval(days) * 86_400))
        let sorted = announcements.sorted { (CanvasClient.date($0.postedAtRFC3339) ?? .distantPast) > (CanvasClient.date($1.postedAtRFC3339) ?? .distantPast) }
        self.logger.info("[canvas-read] announcements days=\(days) courses=\(courses.count) count=\(announcements.count)")
        return [
            "since": CanvasClient.rfc3339(current.addingTimeInterval(-TimeInterval(days) * 86_400)),
            "announcements": sorted.prefix(limit).map { announcement -> [String: Any] in
                var out: [String: Any] = ["id": announcement.id, "title": announcement.title, "text": announcement.text]
                if let courseID = announcement.courseID {
                    out["courseID"] = courseID
                    if let name = names[courseID] { out["course"] = name }
                }
                if let author = announcement.author { out["author"] = author }
                if let posted = announcement.postedAtRFC3339 { out["postedAt"] = posted }
                if let link = announcement.link { out["link"] = link }
                return out
            },
            "total": announcements.count,
            "readAt": CanvasClient.rfc3339(current),
            "nextStep": "Summarise per course, newest first, one line each with its link. Anything with a date or time is a candidate calendar event: offer it and let the person choose. Read-only.",
        ]
    }

    // MARK: Parameters and results

    private struct ParameterError: Error { let message: String; init(_ message: String) { self.message = message } }

    private static func parameters(from paramsJSON: String?) -> [String: Any]? {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard paramsJSON.utf8.count <= 4_096,
              let object = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any]
        else { return nil }
        return object.filter { !($0.value is NSNull) }
    }

    private static func integer(_ raw: Any?, name: String, range: ClosedRange<Int>, default value: Int) throws -> Int {
        guard let raw else { return value }
        guard let number = raw as? NSNumber, range.contains(number.intValue) else {
            throw ParameterError("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number.intValue
    }

    private static func encode(_ payload: [String: Any]) -> GatewayNodeCommandResult {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= Self.maxPayloadBytes else {
            return .failure(code: "RESPONSE_TOO_LARGE", message: "Canvas returned too much to hand over; ask for fewer days or a smaller limit")
        }
        return .success(payloadJSON: String(decoding: data, as: UTF8.self))
    }

    private static func failure(for error: CanvasClientError) -> GatewayNodeCommandResult {
        switch error {
        case .notConnected:
            .failure(code: "NOT_CONNECTED", message: "Canvas is not connected on this iPhone, or the saved sign-in has expired. The person can sign in again under Connect accounts > Canvas.")
        case .notVisible:
            .failure(code: "NOT_VISIBLE", message: "Canvas answered that this is not visible to the person's account.")
        case let .rateLimited(seconds):
            .failure(code: "RATE_LIMITED", message: "Canvas asked Operator to slow down; try again in about \(seconds) seconds. Do not retry now.")
        case .invalidResponse:
            .failure(code: "INVALID_RESPONSE", message: "Canvas answered in a shape Operator did not expect.")
        case .unavailable:
            .failure(code: "UNAVAILABLE", message: "Canvas could not be reached.")
        }
    }
}
