import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

/// Answers each route from a script; records every request so the tests can
/// prove what reached Discord and what never did.
private actor RoutedTransport: PhoneHTTPTransport {
    struct Reply {
        let status: Int; let body: String; let headers: [String: String]
        static func ok(_ body: String) -> Reply { Reply(status: 200, body: body, headers: [:]) }
    }
    private var replies: [String: [Reply]]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [String: [Reply]]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        let path = request.url!.path.replacingOccurrences(of: "/api/v10", with: "")
        guard var queue = self.replies[path], !queue.isEmpty else { throw URLError(.badServerResponse) }
        let reply = queue.removeFirst()
        self.replies[path] = queue
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }

    func paths() -> [String] {
        self.requests.map { $0.url!.path.replacingOccurrences(of: "/api/v10", with: "") + ($0.url!.query.map { "?" + $0 } ?? "") }
    }
}

private final class MemoryHistory: DiscordReadHistoryStore, @unchecked Sendable {
    var passes: [Date] = []
    var pausedUntil: Date?
    func loadPassDates() -> [Date] { self.passes }
    func savePassDates(_ dates: [Date]) { self.passes = dates }
    func loadPausedUntil() -> Date? { self.pausedUntil }
    func savePausedUntil(_ date: Date?) { self.pausedUntil = date }
}

private final class MemoryCache: DiscordReadCacheStore, @unchecked Sendable {
    var cache: DiscordReadCache?
    var saves = 0
    func load() -> DiscordReadCache? { self.cache }
    func save(_ cache: DiscordReadCache) { self.cache = cache; self.saves += 1 }
}

private let general = DiscordChannelEntry(id: "111111111111111111", name: "announcements", guildName: "Robotics Club", guildID: "999999999999999999")
private let events = DiscordChannelEntry(id: "222222222222222222", name: "events", guildName: "CS Society", guildID: "888888888888888888")
/// Long enough to pass the shape check; plainly not a real token.
private let fixtureToken = "fixture-token-" + String(repeating: "x", count: 40)
private let messagesBody = #"""
[
 {"id":"333333333333333333","timestamp":"2026-09-15T14:00:00.000000+00:00","content":"Hack night Thursday 7pm in ECE 101! Bring laptops.","author":{"id":"1","username":"prez","global_name":"Club President"},"attachments":[{"id":"a"}],"embeds":[]},
 {"id":"333333333333333332","timestamp":"2026-09-14T09:30:00.000000+00:00","content":"","author":{"id":"2","username":"bot","global_name":null},"attachments":[],"embeds":[{"title":"Dues reminder","description":"Pay by Sept 20."}]},
 {"id":"333333333333333331","timestamp":"2026-09-10T09:30:00.000000+00:00","content":"old","author":{"username":"someone"},"attachments":[]}
]
"""#

@MainActor
final class DiscordUserClientTests: XCTestCase {
    func testMessagesUseTheOwnersTokenBareWithTheIOSClientShapeAndOnlyAGet() async throws {
        let transport = RoutedTransport(["/channels/111111111111111111/messages": [.ok(messagesBody)]])
        let client = DiscordUserClient(transport: transport, token: { fixtureToken })
        let messages = try await client.messages(in: general, limit: 25)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://discord.com/api/v10/channels/111111111111111111/messages?limit=25")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), fixtureToken, "a user token is sent bare, never as Bearer")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Discord-iOS/") ?? false)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Super-Properties"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].author, "Club President", "display name over handle")
        XCTAssertEqual(messages[0].text, "Hack night Thursday 7pm in ECE 101! Bring laptops.")
        XCTAssertEqual(messages[0].attachmentCount, 1)
        XCTAssertEqual(messages[0].link, "https://discord.com/channels/999999999999999999/111111111111111111/333333333333333333")
        XCTAssertEqual(messages[1].author, "bot", "handle when there is no display name")
        XCTAssertEqual(messages[1].text, "[embed] Dues reminder - Pay by Sept 20.", "announcements are often embeds with no content")
        XCTAssertEqual(messages[2].author, "someone")
    }

    func testStatusCodesMapToBoundedErrorsAndNothingRetries() async throws {
        let cases: [(Int, DiscordUserClientError)] = [(401, .notConnected), (403, .notVisible), (404, .notVisible), (500, .unavailable)]
        for (status, expected) in cases {
            let transport = RoutedTransport(["/channels/111111111111111111/messages": [.init(status: status, body: "{}", headers: [:])]])
            let client = DiscordUserClient(transport: transport, token: { fixtureToken })
            do { _ = try await client.messages(in: general, limit: 5); XCTFail("\(status)") } catch let error as DiscordUserClientError { XCTAssertEqual(error, expected, "\(status)") }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "\(status): one request, no retry")
        }
        let limited = RoutedTransport(["/channels/111111111111111111/messages": [.init(status: 429, body: "{}", headers: ["Retry-After": "12.5"])]])
        do { _ = try await DiscordUserClient(transport: limited, token: { fixtureToken }).messages(in: general, limit: 5); XCTFail() }
        catch let error as DiscordUserClientError { XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 13)) }
        // No token, or one that cannot be a token: nothing is sent at all.
        for bad in [nil, "", "short", "has space " + fixtureToken] {
            let transport = RoutedTransport([:])
            do { _ = try await DiscordUserClient(transport: transport, token: { bad }).messages(in: general, limit: 5); XCTFail() }
            catch let error as DiscordUserClientError { XCTAssertEqual(error, .notConnected) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 0)
        }
    }

    func testChannelResolutionMakesExactlyTwoRequestsAndKeepsNamesBounded() async throws {
        let transport = RoutedTransport([
            "/channels/111111111111111111": [.ok(#"{"id":"111111111111111111","name":"\#(String(repeating: "n", count: 150))","guild_id":"999999999999999999"}"#)],
            "/guilds/999999999999999999": [.ok(#"{"id":"999999999999999999","name":"Robotics Club"}"#)],
        ])
        let entry = try await DiscordUserClient(transport: transport, token: { fixtureToken }).channel(id: "111111111111111111")
        XCTAssertEqual(entry.name.count, 100)
        XCTAssertEqual(entry.guildName, "Robotics Club")
        XCTAssertEqual(entry.guildID, "999999999999999999")
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["/channels/111111111111111111", "/guilds/999999999999999999"])
        do { _ = try await DiscordUserClient(transport: transport, token: { fixtureToken }).channel(id: "../users/@me"); XCTFail() }
        catch let error as DiscordUserClientError { XCTAssertEqual(error, .invalidResponse) }
    }
}

@MainActor
final class DiscordReadPaceTests: XCTestCase {
    func testFourPassesADayTwoHoursApartAndADayOffAfterA429() {
        let history = MemoryHistory()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let pace = DiscordReadPace(history: history, now: { now })
        XCTAssertNil(pace.check())
        pace.recordPass()
        XCTAssertEqual(pace.check(), .tooSoon(retryAfterSeconds: 7_200))
        now = now.addingTimeInterval(7_199)
        XCTAssertEqual(pace.check(), .tooSoon(retryAfterSeconds: 1))
        now = now.addingTimeInterval(1)
        XCTAssertNil(pace.check())
        for _ in 0..<3 { pace.recordPass(); now = now.addingTimeInterval(7_200) }
        XCTAssertEqual(pace.passesLeftToday, 0)
        guard case .dailyCapReached = pace.check() else { return XCTFail("fourth pass used the day") }
        now = now.addingTimeInterval(86_400)
        XCTAssertNil(pace.check(), "a day later the ration is back")
        XCTAssertEqual(pace.passesLeftToday, 4)

        pace.recordRateLimit()
        XCTAssertEqual(pace.check(), .paused(resumesInSeconds: 86_400))
        now = now.addingTimeInterval(86_401)
        XCTAssertNil(pace.check())
        XCTAssertTrue(DiscordReadRefusal.paused(resumesInSeconds: 3_600).message.contains("Do not retry"))
    }

    func testTheHistorySurvivesInTheStoreNotTheObject() {
        let history = MemoryHistory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        DiscordReadPace(history: history, now: { now }).recordPass()
        XCTAssertEqual(DiscordReadPace(history: history, now: { now.addingTimeInterval(60) }).check(), .tooSoon(retryAfterSeconds: 7_140))
    }
}

@MainActor
final class DiscordAccountSetupModelTests: XCTestCase {
    private final class Box: @unchecked Sendable { var token: String?; var channels: [DiscordChannelEntry] = [] }

    private func storage(_ box: Box) -> DiscordAccountStorage {
        .init(loadToken: { box.token }, saveToken: { box.token = $0 }, clearToken: { box.token = nil },
              loadChannels: { box.channels }, saveChannels: { box.channels = $0 })
    }

    func testChannelLinksAndBareIdsParseAndAnythingElseDoesNot() {
        XCTAssertEqual(DiscordAccountSetupModel.channelID(from: "https://discord.com/channels/999999999999999999/111111111111111111"), "111111111111111111")
        XCTAssertEqual(DiscordAccountSetupModel.channelID(from: " https://discord.com/channels/999999999999999999/111111111111111111/333333333333333333 "), "111111111111111111", "a message link names its channel")
        XCTAssertEqual(DiscordAccountSetupModel.channelID(from: "https://ptb.discord.com/channels/999999999999999999/111111111111111111"), "111111111111111111")
        XCTAssertEqual(DiscordAccountSetupModel.channelID(from: "111111111111111111"), "111111111111111111")
        for bad in ["https://discord.com/channels/@me/111111111111111111", "https://evil.example/channels/999999999999999999/111111111111111111", "not a link", "https://discord.com/invite/abc", ""] {
            XCTAssertNil(DiscordAccountSetupModel.channelID(from: bad), bad)
        }
    }

    func testSavingATokenVerifiesItOnceAndABadOneIsNotKept() async {
        let box = Box()
        let transport = RoutedTransport(["/users/@me": [.ok(#"{"id":"1","username":"surya_alt"}"#), .init(status: 401, body: "{}", headers: [:])]])
        let model = DiscordAccountSetupModel(storage: self.storage(box), transport: transport)
        let rejected = await model.saveToken("nope")
        XCTAssertFalse(rejected)
        XCTAssertNil(box.token)
        let saved = await model.saveToken(" \(fixtureToken)\n")
        XCTAssertTrue(saved)
        XCTAssertEqual(box.token, fixtureToken)
        XCTAssertEqual(model.state, DiscordAccountSetupState.connected(username: "surya_alt"))
        let unauthorised = await model.saveToken(fixtureToken + "x")
        XCTAssertFalse(unauthorised, "Discord said 401")
        XCTAssertNil(box.token, "a rejected token is not left in the Keychain")
        XCTAssertEqual(model.state, DiscordAccountSetupState.setupRequired)
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["/users/@me", "/users/@me"])
    }

    func testAddingAChannelResolvesItOnceRefusesDuplicatesAndKeepsTheList() async {
        let box = Box()
        box.token = fixtureToken
        let transport = RoutedTransport([
            "/channels/111111111111111111": [.ok(#"{"id":"111111111111111111","name":"announcements","guild_id":"999999999999999999"}"#)],
            "/guilds/999999999999999999": [.ok(#"{"name":"Robotics Club"}"#)],
            "/channels/222222222222222222": [.init(status: 403, body: "{}", headers: [:])],
        ])
        let model = DiscordAccountSetupModel(storage: self.storage(box), transport: transport)
        await model.check()
        let added = await model.addChannel("https://discord.com/channels/999999999999999999/111111111111111111")
        XCTAssertTrue(added)
        XCTAssertEqual(box.channels, [general])
        let duplicate = await model.addChannel("111111111111111111")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.message, "That channel is already on the list.")
        let invisible = await model.addChannel("222222222222222222")
        XCTAssertFalse(invisible)
        XCTAssertTrue(model.message?.contains("not visible") ?? false)
        XCTAssertEqual(box.channels.count, 1)
        model.removeChannel(id: general.id)
        XCTAssertEqual(box.channels, [])
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["/channels/111111111111111111", "/guilds/999999999999999999", "/channels/222222222222222222"])
    }
}

@MainActor
final class ForegroundDiscordAnnouncementsServiceTests: XCTestCase {
    private func service(_ transport: RoutedTransport, channels: [DiscordChannelEntry], history: MemoryHistory = MemoryHistory(), cache: MemoryCache = MemoryCache(), now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }) -> ForegroundDiscordAnnouncementsService {
        ForegroundDiscordAnnouncementsService(
            client: DiscordUserClient(transport: transport, token: { fixtureToken }),
            channels: { channels },
            pace: DiscordReadPace(history: history, now: now),
            cache: cache,
            now: now)
    }

    private func object(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case let .success(payload) = result else { throw XCTSkip("not a success: \(result)") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    func testAPassReadsEachListedChannelOnceAndTellsTheModelHowToUseIt() async throws {
        let transport = RoutedTransport([
            "/channels/111111111111111111/messages": [.ok(messagesBody)],
            "/channels/222222222222222222/messages": [.ok("[]")],
        ])
        let history = MemoryHistory()
        let result = await self.service(transport, channels: [general, events], history: history).handleNodeCommand("discord.announcements", paramsJSON: #"{"limit":10}"#, timeoutMilliseconds: nil)
        let object = try self.object(result)
        let channels = try XCTUnwrap(object["channels"] as? [[String: Any]])
        XCTAssertEqual(channels.map { $0["server"] as? String }, ["Robotics Club", "CS Society"])
        XCTAssertEqual((channels[0]["messages"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((channels[1]["messages"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(object["passesLeftToday"] as? Int, 3)
        XCTAssertEqual(object["fromCache"] as? Bool, false)
        XCTAssertTrue((object["nextStep"] as? String ?? "").contains("googleCalendarCreateEvent"))
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["/channels/111111111111111111/messages?limit=10", "/channels/222222222222222222/messages?limit=10"])
        XCTAssertEqual(history.passes.count, 1)
    }

    func testSinceFiltersOutOlderMessages() async throws {
        let transport = RoutedTransport(["/channels/111111111111111111/messages": [.ok(messagesBody)]])
        let result = await self.service(transport, channels: [general]).handleNodeCommand("discord.announcements", paramsJSON: #"{"sinceRFC3339":"2026-09-14T00:00:00Z"}"#, timeoutMilliseconds: nil)
        let object = try self.object(result)
        let messages = try XCTUnwrap((object["channels"] as? [[String: Any]])?[0]["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["id"] as? String }, ["333333333333333333", "333333333333333332"])
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["/channels/111111111111111111/messages?limit=25"], "the default limit; since filters locally")
    }

    func testThePaceGuardRefusesBeforeAnyRequestAndWithNothingCachedTheRefusalNamesTheWait() async {
        let transport = RoutedTransport([:])
        let history = MemoryHistory()
        history.passes = [Date(timeIntervalSince1970: 1_800_000_000 - 600)]
        let result = await self.service(transport, channels: [general], history: history).handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil)
        guard case let .failure(code, message) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(code, "RATE_LIMITED")
        XCTAssertTrue(message.contains("Do not retry"))
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(history.passes.count, 1, "a refused pass is not counted")
    }

    func testARefusedPassIsAnsweredFromThePreviousOneWithNoRequestAndSaysSo() async throws {
        let transport = RoutedTransport([
            "/channels/111111111111111111/messages": [.ok(messagesBody)],
            "/channels/222222222222222222/messages": [.ok("[]")],
        ])
        let history = MemoryHistory()
        let cache = MemoryCache()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let service = self.service(transport, channels: [general, events], history: history, cache: cache, now: { clock })
        _ = try self.object(await service.handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil))
        XCTAssertEqual(cache.saves, 1)
        XCTAssertEqual(cache.cache?.channels.map(\.id), [general.id, events.id])
        XCTAssertEqual(cache.cache?.channels[0].messages.count, 3, "the cache keeps the whole read, unfiltered")

        clock = clock.addingTimeInterval(40 * 60)
        let again = try self.object(await service.handleNodeCommand("discord.announcements", paramsJSON: #"{"sinceRFC3339":"2026-09-14T00:00:00Z","limit":1}"#, timeoutMilliseconds: nil))
        XCTAssertEqual(again["fromCache"] as? Bool, true)
        XCTAssertEqual(again["readAt"] as? String, "2027-01-15T08:00:00Z", "the previous pass's time, not now")
        let note = try XCTUnwrap(again["note"] as? String)
        XCTAssertTrue(note.contains("Do not retry before then"), note)
        XCTAssertTrue(note.contains("previous read, made 40 minutes ago"), note)
        let channels = try XCTUnwrap(again["channels"] as? [[String: Any]])
        XCTAssertEqual(channels.map { $0["server"] as? String }, ["Robotics Club", "CS Society"])
        XCTAssertEqual((channels[0]["messages"] as? [[String: Any]])?.map { $0["id"] as? String }, ["333333333333333333"], "since and limit apply to the cached read")
        XCTAssertEqual(again["passesLeftToday"] as? Int, 3)
        let count = await transport.requests.count
        XCTAssertEqual(count, 2, "the second ask reached Discord zero times")
        XCTAssertEqual(history.passes.count, 1)
        XCTAssertEqual(cache.saves, 1, "serving the cache does not rewrite it")
    }

    func testThePreviousPassIsCutToTheChannelsListedNowAndIsNotReplacedByAPassThatReadNothing() async throws {
        let cache = MemoryCache()
        let history = MemoryHistory()
        cache.cache = .init(
            readAt: Date(timeIntervalSince1970: 1_800_000_000 - 3_600), limit: 25,
            channels: [
                .init(id: general.id, name: general.name, server: general.guildName, messages: [.init(id: "1", at: "2026-09-15T14:00:00Z", author: "prez", text: "hi", link: "https://discord.com/channels/9/1/1", attachments: 0)], error: nil),
                .init(id: events.id, name: events.name, server: events.guildName, messages: [], error: nil),
            ],
            note: nil)
        history.passes = [Date(timeIntervalSince1970: 1_800_000_000 - 3_600)]

        // events was removed from the list since the cached pass.
        let refused = try self.object(await self.service(RoutedTransport([:]), channels: [general], history: history, cache: cache).handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil))
        XCTAssertEqual((refused["channels"] as? [[String: Any]])?.map { $0["id"] as? String }, [general.id])

        // Nothing listed now was in the cached pass: the refusal stands, nothing is served.
        let third = DiscordChannelEntry(id: "444444444444444444", name: "third", guildName: "Added Since", guildID: "777777777777777777")
        let nothingShared = await self.service(RoutedTransport([:]), channels: [third], history: history, cache: cache).handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil)
        guard case .failure(let code, _) = nothingShared, code == "RATE_LIMITED" else { return XCTFail("\(nothingShared)") }
        XCTAssertEqual(history.passes.count, 1)

        // A fresh pass in which every channel fails leaves the previous pass in place.
        history.passes = []
        let failing = RoutedTransport(["/channels/111111111111111111/messages": [.init(status: 500, body: "{}", headers: [:])]])
        let failed = try self.object(await self.service(failing, channels: [general], history: history, cache: cache).handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil))
        XCTAssertEqual((failed["channels"] as? [[String: Any]])?.first?["error"] as? String, "could not be read")
        XCTAssertEqual(cache.saves, 0)
        XCTAssertEqual(cache.cache?.channels.first?.messages.first?.id, "1")
    }

    func testTheFileStoreRoundTripsAPassAndAnsweredNothingBeforeOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discord-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDiscordReadCacheStore(supportDirectory: directory)
        XCTAssertNil(store.load())
        let pass = DiscordReadCache(
            readAt: Date(timeIntervalSince1970: 1_800_000_000), limit: 10,
            channels: [.init(id: general.id, name: general.name, server: general.guildName, messages: [.init(id: "1", at: "2026-09-15T14:00:00Z", author: "prez", text: "Hack night", link: "https://discord.com/channels/9/1/1", attachments: 1)], error: nil)],
            note: "ended early")
        store.save(pass)
        XCTAssertEqual(FileDiscordReadCacheStore(supportDirectory: directory).load(), pass)
    }

    func testA429EndsThePassPausesForADayAndStillReportsWhatWasRead() async throws {
        let transport = RoutedTransport([
            "/channels/111111111111111111/messages": [.ok(messagesBody)],
            "/channels/222222222222222222/messages": [.init(status: 429, body: "{}", headers: ["Retry-After": "5"])],
        ])
        let history = MemoryHistory()
        let third = DiscordChannelEntry(id: "444444444444444444", name: "third", guildName: "Never Read", guildID: "777777777777777777")
        let result = await self.service(transport, channels: [general, events, third], history: history).handleNodeCommand("discord.announcements", paramsJSON: "{}", timeoutMilliseconds: nil)
        let object = try self.object(result)
        XCTAssertEqual((object["channels"] as? [[String: Any]])?.count, 1, "the channel that hit 429 and everything after it are not in the result")
        XCTAssertTrue((object["note"] as? String ?? "").contains("paused for a day"))
        let count = await transport.requests.count
        XCTAssertEqual(count, 2, "the third channel was never requested")
        XCTAssertNotNil(history.pausedUntil)
        XCTAssertEqual(object["passesLeftToday"] as? Int, 3)
    }

    func testAnInvalidTokenEndsThePassAndAnInvisibleChannelIsReportedInPlace() async throws {
        let unauthorised = RoutedTransport(["/channels/111111111111111111/messages": [.init(status: 401, body: "{}", headers: [:])]])
        let result = await self.service(unauthorised, channels: [general]).handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil)
        guard case let .failure(code, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(code, "NOT_CONNECTED")

        let forbidden = RoutedTransport([
            "/channels/111111111111111111/messages": [.init(status: 403, body: "{}", headers: [:])],
            "/channels/222222222222222222/messages": [.ok("[]")],
        ])
        let partial = await self.service(forbidden, channels: [general, events]).handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil)
        let channels = try XCTUnwrap(try self.object(partial)["channels"] as? [[String: Any]])
        XCTAssertEqual(channels[0]["error"] as? String, "not visible to this account")
        XCTAssertEqual((channels[1]["messages"] as? [Any])?.count, 0)
    }

    func testNoChannelsBadParametersAndOtherCommandsAreRefusedWithoutARequest() async {
        let transport = RoutedTransport([:])
        let none = await self.service(transport, channels: []).handleNodeCommand("discord.announcements", paramsJSON: nil, timeoutMilliseconds: nil)
        guard case let .failure(code, _) = none else { return XCTFail() }
        XCTAssertEqual(code, "NOT_CONFIGURED")
        for bad in [#"{"limit":0}"#, #"{"limit":51}"#, #"{"sinceRFC3339":"yesterday"}"#, #"{"channel":"111111111111111111"}"#, "[]"] {
            let result = await self.service(transport, channels: [general]).handleNodeCommand("discord.announcements", paramsJSON: bad, timeoutMilliseconds: nil)
            guard case let .failure(code, _) = result else { return XCTFail(bad) }
            XCTAssertEqual(code, "INVALID_REQUEST", bad)
        }
        let other = await self.service(transport, channels: [general]).handleNodeCommand("discord.post", paramsJSON: nil, timeoutMilliseconds: nil)
        guard case let .failure(otherCode, _) = other else { return XCTFail() }
        XCTAssertEqual(otherCode, "UNSUPPORTED_COMMAND")
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
}
