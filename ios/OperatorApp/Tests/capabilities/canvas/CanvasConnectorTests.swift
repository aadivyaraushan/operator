import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

/// Answers each path from a script; records every request so the tests can
/// prove what reached Canvas, in what shape, and what never did.
private actor RoutedTransport: PhoneHTTPTransport {
    struct Reply {
        let status: Int; let body: String; let headers: [String: String]
        static func ok(_ body: String, headers: [String: String] = [:]) -> Reply { Reply(status: 200, body: body, headers: headers) }
    }
    private var replies: [String: [Reply]]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [String: [Reply]]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        let path = request.url!.path
        guard var queue = self.replies[path], !queue.isEmpty else { throw URLError(.badServerResponse) }
        let reply = queue.removeFirst()
        self.replies[path] = queue
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }

    func urls() -> [String] { self.requests.map { $0.url!.absoluteString } }
}

private let school = URL(string: "https://canvas.illinois.edu")!
/// Long enough to pass the shape check; plainly not a real token.
private let fixtureToken = "1234~fixture" + String(repeating: "x", count: 40)

private let coursesBody = #"""
[
 {"id":101,"name":"CS 225: Data Structures","course_code":"CS225","term":{"name":"Fall 2026"},"enrollments":[{"type":"student","computed_current_score":91.4,"computed_current_grade":"A-"}]},
 {"id":102,"name":"MATH 241","course_code":"MATH241","enrollments":[{"type":"student"}]},
 {"id":"bad","name":""}
]
"""#
private let plannerBody = #"""
[
 {"plannable_type":"quiz","plannable_date":"2026-09-20T04:59:00Z","context_name":"MATH 241","course_id":102,"plannable":{"id":7,"title":"Quiz 3","due_at":"2026-09-20T04:59:00Z","points_possible":10},"submissions":{"submitted":false,"missing":false,"late":false},"html_url":"https://canvas.illinois.edu/courses/102/quizzes/7"},
 {"plannable_type":"assignment","plannable_date":"2026-09-18T04:59:00Z","context_name":"CS 225: Data Structures","course_id":101,"plannable":{"id":5,"title":"MP2","due_at":"2026-09-18T04:59:00Z","points_possible":100},"submissions":{"submitted":true,"missing":false,"late":false},"html_url":"https://canvas.illinois.edu/courses/101/assignments/5"},
 {"plannable_type":"planner_note","plannable_date":"2026-09-19T00:00:00Z","plannable":{"id":9,"title":"Office hours"},"submissions":false}
]
"""#
private let missingBody = #"""
[{"id":3,"name":"Lab 1","course_id":101,"due_at":"2026-09-10T04:59:00Z","points_possible":20,"html_url":"https://canvas.illinois.edu/courses/101/assignments/3"}]
"""#
private let announcementsBody = #"""
[
 {"id":900,"title":"Midterm room change","message":"<p>The midterm is in <b>Siebel 1404</b>, not 2405.<br>Bring a pencil &amp; ID.</p><script>x()</script>","context_code":"course_101","posted_at":"2026-09-16T15:00:00Z","author":{"display_name":"Prof. Chen"},"html_url":"https://canvas.illinois.edu/courses/101/discussion_topics/900"},
 {"id":901,"title":"Homework 4 posted","message":"Due Friday.","context_code":"course_102","posted_at":"2026-09-17T12:00:00Z","html_url":"http://insecure.example/x"}
]
"""#

private let fixedNow = Date(timeIntervalSince1970: 1_789_660_800) // 2026-09-17T16:00:00Z
private enum CanvasTestFailure: Error { case notSuccess }

@MainActor
final class CanvasClientTests: XCTestCase {
    func testCoursesAreAGetWithBearerTokenAndTotalScoresAndDecodeGrades() async throws {
        let transport = RoutedTransport(["/api/v1/courses": [.ok(coursesBody)]])
        let client = CanvasClient(transport: transport, baseURL: { school }, token: { fixtureToken })
        let courses = try await client.courses()
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fixtureToken)")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://canvas.illinois.edu/api/v1/courses?"), url)
        XCTAssertTrue(url.contains("enrollment_state=active") && url.contains("include%5B%5D=total_scores") && url.contains("per_page=50"), url)
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(courses.map(\.id), [101, 102], "the malformed row is dropped")
        XCTAssertEqual(courses[0].currentGrade, "A-")
        XCTAssertEqual(courses[0].currentScore, 91.4)
        XCTAssertEqual(courses[0].term, "Fall 2026")
        XCTAssertNil(courses[1].currentScore, "a course that hides grades has none")
    }

    func testPagesFollowTheLinkHeaderOnTheSchoolsHostOnlyAndStopAtTheCap() async throws {
        let next = #"<https://canvas.illinois.edu/api/v1/courses?page=2&per_page=50>; rel="next", <https://canvas.illinois.edu/api/v1/courses?page=1>; rel="first""#
        let elsewhere = #"<https://evil.example/api/v1/courses?page=3>; rel="next""#
        let transport = RoutedTransport(["/api/v1/courses": [
            .ok(#"[{"id":1,"name":"A"}]"#, headers: ["Link": next]),
            .ok(#"[{"id":2,"name":"B"}]"#, headers: ["Link": elsewhere]),
            .ok(#"[{"id":3,"name":"C"}]"#),
        ]])
        let courses = try await CanvasClient(transport: transport, baseURL: { school }, token: { fixtureToken }).courses()
        XCTAssertEqual(courses.map(\.id), [1, 2], "the next link on another host is not followed")
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testStatusCodesMapToBoundedErrorsAndNothingRetriesOrSendsWithoutAToken() async throws {
        for (status, expected) in [(401, CanvasClientError.notConnected), (403, .notVisible), (404, .notVisible), (500, .unavailable)] {
            let transport = RoutedTransport(["/api/v1/courses": [.init(status: status, body: "{}", headers: [:])]])
            do { _ = try await CanvasClient(transport: transport, baseURL: { school }, token: { fixtureToken }).courses(); XCTFail("\(status)") }
            catch let error as CanvasClientError { XCTAssertEqual(error, expected, "\(status)") }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
        let limited = RoutedTransport(["/api/v1/courses": [.init(status: 429, body: "{}", headers: ["Retry-After": "30"])]])
        do { _ = try await CanvasClient(transport: limited, baseURL: { school }, token: { fixtureToken }).courses(); XCTFail() }
        catch let error as CanvasClientError { XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 30)) }
        for (base, token) in [(nil, fixtureToken), (school, nil), (school, "short"), (school, "has space " + fixtureToken)] as [(URL?, String?)] {
            let transport = RoutedTransport([:])
            do { _ = try await CanvasClient(transport: transport, baseURL: { base }, token: { token }).courses(); XCTFail() }
            catch let error as CanvasClientError { XCTAssertEqual(error, .notConnected) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 0, "nothing is sent without an address and a plausible token")
        }
    }

    func testAnnouncementBodiesBecomeBoundedTextAndInsecureLinksAreDropped() {
        XCTAssertEqual(CanvasClient.plainText("<p>The midterm is in <b>Siebel 1404</b>, not 2405.<br>Bring a pencil &amp; ID.</p>"), "The midterm is in Siebel 1404, not 2405.\nBring a pencil & ID.")
        XCTAssertEqual(CanvasClient.plainText(String(repeating: "<i>a</i>", count: 5_000)).count, CanvasClient.textLimit)
        let objects = try! JSONSerialization.jsonObject(with: Data(announcementsBody.utf8)) as! [[String: Any]]
        let second = try! XCTUnwrap(CanvasClient.announcement(from: objects[1]))
        XCTAssertNil(second.link, "http links are not handed to the model")
        XCTAssertEqual(second.courseID, 102)
        XCTAssertNil(second.author)
    }

    func testTheSchoolAddressIsNormalisedToAnHTTPSOrigin() {
        XCTAssertEqual(CanvasClient.baseURL(from: "canvas.illinois.edu")?.absoluteString, "https://canvas.illinois.edu")
        XCTAssertEqual(CanvasClient.baseURL(from: " https://Canvas.Stanford.edu/courses/1 ")?.absoluteString, "https://canvas.stanford.edu")
        XCTAssertNil(CanvasClient.baseURL(from: "http://canvas.illinois.edu"))
        XCTAssertNil(CanvasClient.baseURL(from: "localhost"))
        XCTAssertNil(CanvasClient.baseURL(from: "canvas.illinois.edu:8443"))
        XCTAssertNil(CanvasClient.baseURL(from: ""))
    }
}

@MainActor
final class ForegroundCanvasServiceTests: XCTestCase {
    private func service(_ replies: [String: [RoutedTransport.Reply]]) -> (ForegroundCanvasService, RoutedTransport) {
        let transport = RoutedTransport(replies)
        let client = CanvasClient(transport: transport, baseURL: { school }, token: { fixtureToken })
        return (ForegroundCanvasService(client: client, now: { fixedNow }), transport)
    }

    private func payload(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case let .success(json) = result else {
            XCTFail("expected success, got \(result)")
            throw CanvasTestFailure.notSuccess
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testCoursesReturnGradesWhereShownAndTakeNoParameters() async throws {
        let (service, _) = self.service(["/api/v1/courses": [.ok(coursesBody)]])
        let object = try self.payload(await service.handleNodeCommand("canvas.courses", paramsJSON: "{}", timeoutMilliseconds: nil))
        let courses = try XCTUnwrap(object["courses"] as? [[String: Any]])
        XCTAssertEqual(courses.count, 2)
        XCTAssertEqual(courses[0]["currentGrade"] as? String, "A-")
        XCTAssertNil(courses[1]["currentScore"])
        XCTAssertTrue((object["nextStep"] as? String)?.contains("Read-only") ?? false)

        guard case let .failure(code, _) = await service.handleNodeCommand("canvas.courses", paramsJSON: #"{"days":3}"#, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(code, "INVALID_REQUEST")
    }

    func testUpcomingCoversTheWindowSortsByDueAndAddsMissingSubmissions() async throws {
        let (service, transport) = self.service([
            "/api/v1/planner/items": [.ok(plannerBody), .ok("[]")],
            "/api/v1/users/self/missing_submissions": [.ok(missingBody), .ok("[]")],
        ])
        let object = try self.payload(await service.handleNodeCommand("canvas.upcoming", paramsJSON: nil, timeoutMilliseconds: nil))
        XCTAssertEqual(object["from"] as? String, "2026-09-17T16:00:00Z")
        XCTAssertEqual(object["to"] as? String, "2026-09-24T16:00:00Z", "seven days by default")
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["title"] as? String }, ["MP2", "Office hours", "Quiz 3"], "soonest first")
        XCTAssertEqual(items[0]["submitted"] as? Bool, true)
        XCTAssertEqual(items[0]["course"] as? String, "CS 225: Data Structures")
        XCTAssertEqual(items[2]["points"] as? Double, 10)
        let missing = try XCTUnwrap(object["missing"] as? [[String: Any]])
        XCTAssertEqual(missing.first?["title"] as? String, "Lab 1")
        let urls = await transport.urls()
        XCTAssertTrue(urls[0].contains("start_date=2026-09-17T16:00:00Z") && urls[0].contains("end_date=2026-09-24T16:00:00Z"), urls[0])

        let object3 = try self.payload(await service.handleNodeCommand("canvas.upcoming", paramsJSON: #"{"days":3}"#, timeoutMilliseconds: nil))
        XCTAssertEqual(object3["to"] as? String, "2026-09-20T16:00:00Z")
        guard case let .failure(code, _) = await service.handleNodeCommand("canvas.upcoming", paramsJSON: #"{"days":31}"#, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(code, "INVALID_REQUEST")
    }

    func testAMissingSubmissionsFailureDoesNotLoseTheUpcomingList() async throws {
        let (service, _) = self.service([
            "/api/v1/planner/items": [.ok(plannerBody)],
            "/api/v1/users/self/missing_submissions": [.init(status: 500, body: "", headers: [:])],
        ])
        let object = try self.payload(await service.handleNodeCommand("canvas.upcoming", paramsJSON: nil, timeoutMilliseconds: nil))
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((object["missing"] as? [[String: Any]])?.count, 0)
    }

    func testAnnouncementsReadTheCoursesThenAskForThemByContextCodeNewestFirst() async throws {
        let (service, transport) = self.service([
            "/api/v1/courses": [.ok(coursesBody)],
            "/api/v1/announcements": [.ok(announcementsBody)],
        ])
        let object = try self.payload(await service.handleNodeCommand("canvas.announcements", paramsJSON: #"{"days":7,"limit":10}"#, timeoutMilliseconds: nil))
        let urls = await transport.urls()
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[1].contains("context_codes%5B%5D=course_101") && urls[1].contains("context_codes%5B%5D=course_102"), urls[1])
        XCTAssertTrue(urls[1].contains("start_date=2026-09-10T16:00:00Z"), urls[1])
        let announcements = try XCTUnwrap(object["announcements"] as? [[String: Any]])
        XCTAssertEqual(announcements.map { $0["id"] as? Int }, [901, 900], "newest first")
        XCTAssertEqual(announcements[1]["course"] as? String, "CS 225: Data Structures")
        XCTAssertEqual(announcements[1]["author"] as? String, "Prof. Chen")
        XCTAssertEqual(announcements[1]["text"] as? String, "The midterm is in Siebel 1404, not 2405.\nBring a pencil & ID.\nx()")
        XCTAssertEqual(object["total"] as? Int, 2)
    }

    func testNoTokenIsNotConnectedAndSaysWhereToSetUp() async throws {
        let transport = RoutedTransport([:])
        let client = CanvasClient(transport: transport, baseURL: { school }, token: { nil })
        let service = ForegroundCanvasService(client: client, now: { fixedNow })
        guard case let .failure(code, message) = await service.handleNodeCommand("canvas.courses", paramsJSON: nil, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(code, "NOT_CONNECTED")
        XCTAssertTrue(message.contains("Connect accounts > Canvas"))
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testARateLimitIsReportedWithTheWaitAndNeverRetried() async throws {
        let (service, transport) = self.service(["/api/v1/courses": [.init(status: 429, body: "", headers: ["Retry-After": "45"])]])
        guard case let .failure(code, message) = await service.handleNodeCommand("canvas.courses", paramsJSON: nil, timeoutMilliseconds: nil) else { return XCTFail() }
        XCTAssertEqual(code, "RATE_LIMITED")
        XCTAssertTrue(message.contains("45 seconds"))
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }
}

@MainActor
final class CanvasAccountSetupModelTests: XCTestCase {
    private final class Storage: @unchecked Sendable {
        var token: String?
        var url: URL?
        var storage: CanvasAccountStorage {
            CanvasAccountStorage(
                loadToken: { [self] in self.token }, saveToken: { [self] in self.token = $0 }, clearToken: { [self] in self.token = nil },
                loadBaseURL: { [self] in self.url }, saveBaseURL: { [self] in self.url = $0 })
        }
    }

    func testSavingVerifiesWithOneRequestAndKeepsAddressAndToken() async throws {
        let storage = Storage()
        let transport = RoutedTransport(["/api/v1/users/self": [.ok(#"{"id":1,"name":"Surya S","short_name":"Surya"}"#)]])
        let model = CanvasAccountSetupModel(storage: storage.storage, transport: transport)
        let saved = await model.save(address: "canvas.illinois.edu/", token: fixtureToken)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.state, .connected(name: "Surya S"))
        XCTAssertEqual(storage.url?.absoluteString, "https://canvas.illinois.edu")
        XCTAssertEqual(storage.token, fixtureToken)
        let urls = await transport.urls()
        XCTAssertEqual(urls, ["https://canvas.illinois.edu/api/v1/users/self"])
    }

    func testARejectedTokenSavesNothingAndRestoresTheOldAddress() async throws {
        let storage = Storage()
        storage.url = URL(string: "https://canvas.stanford.edu")
        let transport = RoutedTransport(["/api/v1/users/self": [.init(status: 401, body: "", headers: [:])]])
        let model = CanvasAccountSetupModel(storage: storage.storage, transport: transport)
        let saved = await model.save(address: "canvas.illinois.edu", token: fixtureToken)
        XCTAssertFalse(saved)
        XCTAssertNil(storage.token)
        XCTAssertEqual(storage.url?.host, "canvas.stanford.edu")
        XCTAssertEqual(model.state, .setupRequired)
        XCTAssertEqual(model.message, "Canvas did not accept that token.")
    }

    func testABadAddressOrTokenIsRefusedBeforeAnyRequest() async throws {
        let storage = Storage()
        let transport = RoutedTransport([:])
        let model = CanvasAccountSetupModel(storage: storage.storage, transport: transport)
        let badHost = await model.save(address: "not a host", token: fixtureToken)
        let badToken = await model.save(address: "canvas.illinois.edu", token: "short")
        XCTAssertFalse(badHost)
        XCTAssertFalse(badToken)
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(storage.token)
    }
}
