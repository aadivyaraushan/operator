import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

// Photos, Music, Weather and Device in one suite, the way connections/media
// covers YouTube and podcasts together: four services of the same shape, one
// runner, one place to look when the shape changes.

// MARK: - Photos

@MainActor
final class ForegroundPhotosServiceTests: XCTestCase {
    func testReturnsDescriptionsAndNeverImageData() async throws {
        let library = StubPhotoLibrary(access: .full, items: [
            PhotoItem(id: "A/1", created: Date(timeIntervalSince1970: 1_700_000_000),
                      isVideo: false, isFavorite: true, albumName: "Recents"),
        ])
        let service = ForegroundPhotosService(library: library, isAppActive: { true })

        let result = await service.handleNodeCommand("photos.latest", paramsJSON: "{}", timeoutMilliseconds: nil)

        let payload = try payloadObject(result)
        let photos = try XCTUnwrap(payload["photos"] as? [[String: Any]])
        XCTAssertEqual(Set(photos[0].keys), ["id", "created", "kind", "favorite", "album"])
        XCTAssertEqual(photos[0]["kind"] as? String, "image")
        // Pixels leaving the phone is a separate decision from metadata
        // leaving it, and this service is not the place it gets made.
        guard case .success(let raw) = result else { return XCTFail("expected success") }
        XCTAssertFalse(raw.contains("base64"))
        XCTAssertFalse(raw.contains("data:image"))
    }

    func testPassesAlbumAndWindowThroughAfterTrimming() async {
        let library = StubPhotoLibrary(access: .full, items: [])
        let service = ForegroundPhotosService(library: library, isAppActive: { true })

        _ = await service.handleNodeCommand(
            "photos.latest",
            paramsJSON: #"{"album":"  Receipts  ","from":"2026-09-01T00:00:00Z","to":"2026-09-08T00:00:00Z","limit":3}"#,
            timeoutMilliseconds: nil)

        XCTAssertEqual(library.lastAlbum, "Receipts")
        XCTAssertNotNil(library.lastFrom)
        XCTAssertNotNil(library.lastTo)
        XCTAssertEqual(library.lastLimit, 3)
    }

    func testEnforcesItsLimitAgainstALibraryThatIgnoresIt() async throws {
        let many = (0 ..< 25).map { PhotoItem(id: "\($0)", created: nil, isVideo: false, isFavorite: false, albumName: nil) }
        let service = ForegroundPhotosService(library: StubPhotoLibrary(access: .full, items: many), isAppActive: { true })

        let result = await service.handleNodeCommand("photos.latest", paramsJSON: #"{"limit":2}"#, timeoutMilliseconds: nil)

        XCTAssertEqual((try payloadObject(result)["photos"] as? [[String: Any]])?.count, 2)
    }

    func testRefusesEveryBadShapeWithoutSearching() async {
        let invalid = [
            "[]", "not-json", #"{"limit":0}"#, #"{"limit":26}"#, #"{"limit":true}"#,
            #"{"album":""}"#, #"{"album":"   "}"#, #"{"from":"nope"}"#,
            #"{"from":"2026-09-08T00:00:00Z","to":"2026-09-01T00:00:00Z"}"#, #"{"x":1}"#,
        ]
        for paramsJSON in invalid {
            let library = StubPhotoLibrary(access: .full, items: [])
            let service = ForegroundPhotosService(library: library, isAppActive: { true })

            let result = await service.handleNodeCommand("photos.latest", paramsJSON: paramsJSON, timeoutMilliseconds: nil)

            XCTAssertEqual(result, .failure(
                code: "INVALID_REQUEST",
                message: "photos.latest accepts an optional album, from, to and a limit between 1 and 25"),
                "params=\(paramsJSON)")
            XCTAssertEqual(library.searchCount, 0, "params=\(paramsJSON)")
        }
    }

    func testReportsPartialAccessAndRefusesDenied() async throws {
        let limited = ForegroundPhotosService(library: StubPhotoLibrary(access: .limited, items: []), isAppActive: { true })
        let granted = await limited.handleNodeCommand("photos.latest", paramsJSON: "{}", timeoutMilliseconds: nil)
        XCTAssertEqual(try payloadObject(granted)["partialAccess"] as? Bool, true)

        let library = StubPhotoLibrary(access: .denied, items: [])
        let denied = await ForegroundPhotosService(library: library, isAppActive: { true })
            .handleNodeCommand("photos.latest", paramsJSON: "{}", timeoutMilliseconds: nil)
        XCTAssertEqual(denied, .failure(code: "PERMISSION_DENIED", message: "Photos permission was denied"))
        XCTAssertEqual(library.searchCount, 0)
    }
}

// MARK: - Music

@MainActor
final class ForegroundMusicServiceTests: XCTestCase {
    func testAnswersNowPlayingAndSearchSeparately() async throws {
        let track = MusicTrack(id: "1", title: "Song", artist: "A", album: "B", durationSeconds: 200)
        let nowPlaying = await ForegroundMusicService(
            library: StubMusicLibrary(access: .granted, now: .init(track: track, isPlaying: true)),
            isAppActive: { true })
            .handleNodeCommand("music.nowPlaying", paramsJSON: "{}", timeoutMilliseconds: nil)
        XCTAssertEqual(try payloadObject(nowPlaying)["playing"] as? Bool, true)
        XCTAssertEqual(try payloadObject(nowPlaying)["title"] as? String, "Song")

        let hits = (0 ..< 20).map { MusicTrack(id: "\($0)", title: "t\($0)", artist: nil, album: nil, durationSeconds: nil) }
        let searched = await ForegroundMusicService(
            library: StubMusicLibrary(access: .granted, hits: hits), isAppActive: { true })
            .handleNodeCommand("music.search", paramsJSON: #"{"query":"t","limit":4}"#, timeoutMilliseconds: nil)
        XCTAssertEqual((try payloadObject(searched)["tracks"] as? [[String: Any]])?.count, 4)
    }

    func testSearchNeedsAQueryAndNowPlayingTakesNoParameters() async {
        for paramsJSON in [nil, "{}", #"{"limit":3}"#, #"{"query":"  "}"#, #"{"query":"a","x":1}"#] as [String?] {
            let library = StubMusicLibrary(access: .granted)
            let result = await ForegroundMusicService(library: library, isAppActive: { true })
                .handleNodeCommand("music.search", paramsJSON: paramsJSON, timeoutMilliseconds: nil)

            XCTAssertEqual(result, .failure(
                code: "INVALID_REQUEST",
                message: "music.search requires a nonempty query and an optional limit between 1 and 20"),
                "params=\(String(describing: paramsJSON))")
            XCTAssertEqual(library.searchCount, 0)
        }

        let refused = await ForegroundMusicService(library: StubMusicLibrary(access: .granted), isAppActive: { true })
            .handleNodeCommand("music.nowPlaying", paramsJSON: #"{"query":"x"}"#, timeoutMilliseconds: nil)
        XCTAssertEqual(refused, .failure(code: "INVALID_REQUEST", message: "music.nowPlaying does not accept parameters"))
    }

    // Playback is a write. Reads come first, and nothing here starts audio.
    func testOffersNoPlaybackVerb() async {
        for command in ["music.play", "music.pause", "music.skip"] {
            let result = await ForegroundMusicService(library: StubMusicLibrary(access: .granted), isAppActive: { true })
                .handleNodeCommand(command, paramsJSON: "{}", timeoutMilliseconds: nil)
            XCTAssertEqual(result, .failure(
                code: "UNSUPPORTED_COMMAND",
                message: "This iPhone node does not support \(command)"))
        }
    }
}

// MARK: - Weather

@MainActor
final class ForegroundWeatherServiceTests: XCTestCase {
    func testCarriesAttributionAndValidatesTheCoordinate() async throws {
        let service = ForegroundWeatherService(source: StubWeatherSource(reading: .init(
            temperatureCelsius: 18.5, apparentCelsius: 17.0, condition: "Partly Cloudy",
            humidity: 0.62, windKilometresPerHour: 11.2, highCelsius: 21, lowCelsius: 12, attribution: weatherAttribution)), recordCard: { _ in })

        let result = await service.handleNodeCommand(
            "weather.forecast", paramsJSON: #"{"latitude":41.88,"longitude":-87.63}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(try payloadObject(result)["condition"] as? String, "Partly Cloudy")
        // Apple requires the attribution to travel with the data, so it is in
        // the payload rather than left to a caller to remember.
        XCTAssertEqual(try payloadObject(result)["attribution"] as? String, ForegroundWeatherService.attribution)

        for paramsJSON in [nil, "{}", #"{"latitude":41.88}"#, #"{"latitude":91,"longitude":0}"#,
                           #"{"latitude":0,"longitude":181}"#, #"{"latitude":"a","longitude":0}"#,
                           #"{"latitude":true,"longitude":0}"#, #"{"latitude":0,"longitude":0,"x":1}"#] as [String?] {
            let refused = await service.handleNodeCommand("weather.forecast", paramsJSON: paramsJSON, timeoutMilliseconds: nil)
            XCTAssertEqual(refused, .failure(
                code: "INVALID_REQUEST",
                message: "weather.forecast requires latitude between -90 and 90 and longitude between -180 and 180"),
                "params=\(String(describing: paramsJSON))")
        }
    }

    // Null Island is a real coordinate, and zero is exactly the value that
    // bridges like a boolean. See JSONNumber.
    func testZeroIsAValidCoordinate() {
        XCTAssertNotNil(ForegroundWeatherService.coordinate(from: #"{"latitude":0,"longitude":0}"#))
        XCTAssertNotNil(ForegroundWeatherService.coordinate(from: #"{"latitude":1,"longitude":1}"#))
        XCTAssertNil(ForegroundWeatherService.coordinate(from: #"{"latitude":true,"longitude":0}"#))
    }

    func testDoesNotForwardBackendErrorText() async {
        let result = await ForegroundWeatherService(source: StubWeatherSource(reading: nil), recordCard: { _ in })
            .handleNodeCommand("weather.forecast", paramsJSON: #"{"latitude":0,"longitude":0}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "WEATHER_UNAVAILABLE", message: "Operator could not read the forecast"))
        if case .failure(_, let message) = result {
            XCTAssertFalse(message.contains("stub-backend-detail"), "a backend's own message is not for the agent")
        }
    }

    func testSuccessRecordsTheExactWeatherCardBeforeReturningSuccess() async throws {
        let recorder = WeatherCardRecorder()
        let reading = WeatherReading(temperatureCelsius: 18.5, apparentCelsius: 17, condition: "Partly Cloudy", humidity: 0.62, windKilometresPerHour: 11.2, highCelsius: 21, lowCelsius: 12, attribution: weatherAttribution)
        let service = ForegroundWeatherService(source: StubWeatherSource(reading: reading), recordCard: { try await recorder.record($0) })

        let result = await service.handleNodeCommand("weather.forecast", paramsJSON: #"{"latitude":1,"longitude":2}"#, timeoutMilliseconds: 1_000)

        guard case .success = result else { return XCTFail("Expected success") }
        let cards = await recorder.cards()
        XCTAssertEqual(cards, [.init(temperatureCelsius: reading.temperatureCelsius, apparentCelsius: reading.apparentCelsius, condition: reading.condition, humidity: reading.humidity, windKilometresPerHour: reading.windKilometresPerHour, highCelsius: reading.highCelsius, lowCelsius: reading.lowCelsius, attribution: weatherAttribution)])
    }

    func testFailureTimeoutAndPersistenceErrorDoNotClaimARecordedForecast() async {
        let recorder = WeatherCardRecorder()
        let unavailable = ForegroundWeatherService(source: StubWeatherSource(reading: nil), recordCard: { try await recorder.record($0) })
        let unavailableResult = await unavailable.handleNodeCommand("weather.forecast", paramsJSON: #"{"latitude":1,"longitude":2}"#, timeoutMilliseconds: 1_000)
        XCTAssertEqual(unavailableResult, .failure(code: "WEATHER_UNAVAILABLE", message: "Operator could not read the forecast"))
        let failing = WeatherCardRecorder(fails: true)
        let reading = WeatherReading(temperatureCelsius: 1, apparentCelsius: nil, condition: "Clear", humidity: nil, windKilometresPerHour: nil, highCelsius: nil, lowCelsius: nil, attribution: weatherAttribution)
        let persistence = ForegroundWeatherService(source: StubWeatherSource(reading: reading), recordCard: { try await failing.record($0) })
        let persistenceResult = await persistence.handleNodeCommand("weather.forecast", paramsJSON: #"{"latitude":1,"longitude":2}"#, timeoutMilliseconds: 1_000)
        XCTAssertEqual(persistenceResult, .failure(code: "INTERNAL_ERROR", message: "Operator could not save the forecast"))
        let recorded = await recorder.cards()
        let failedCards = await failing.cards()
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(failedCards.isEmpty)
    }
}

// MARK: - Device

@MainActor
final class ForegroundDeviceServiceTests: XCTestCase {
    func testReportsStateAndNoIdentifierOfAnyKind() async throws {
        let service = ForegroundDeviceService(source: StubDeviceStatusSource(.init(
            batteryLevel: 0.42, charging: false, lowPowerMode: true,
            networkAvailable: true, networkIsExpensive: false,
            localeIdentifier: "en_US", timeZoneIdentifier: "America/Chicago")))

        let payload = try payloadObject(await service.handleNodeCommand("device.status", paramsJSON: nil, timeoutMilliseconds: nil))

        XCTAssertEqual(Set(payload.keys), [
            "batteryLevel", "charging", "lowPowerMode", "online", "meteredConnection", "locale", "timeZone",
        ])
        // None of these identify a person across contexts, and none of them
        // would help an agent decide anything. The absence is the feature.
        for banned in ["identifierForVendor", "deviceId", "name", "model", "udid", "advertising"] {
            XCTAssertNil(payload[banned], banned)
        }
    }

    func testTakesNoParameters() async {
        let service = ForegroundDeviceService(source: StubDeviceStatusSource(.init(
            batteryLevel: nil, charging: nil, lowPowerMode: false, networkAvailable: false,
            networkIsExpensive: false, localeIdentifier: "en_US", timeZoneIdentifier: "UTC")))

        // Hoisted out of the assertion: XCTAssertEqual takes autoclosures,
        // and an await cannot happen inside one.
        let result = await service.handleNodeCommand(
            "device.status", paramsJSON: #"{"x":1}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(
            code: "INVALID_REQUEST", message: "device.status does not accept parameters"))
    }
}

// MARK: - Deadlines

// The gateway hands every handler a timeoutMilliseconds, and these four used
// to discard it. A caller that cannot bound a slow connector has no way to
// stop waiting, and the realistic hang is an owner who never answers a
// permission prompt rather than a slow framework call.
@MainActor
final class NativeReadDeadlineTests: XCTestCase {
    func testASlowPhotoSearchTimesOutRatherThanWaiting() async {
        let library = StubPhotoLibrary(access: .full, items: [])
        library.delayNanoseconds = 2_000_000_000
        let service = ForegroundPhotosService(library: library, isAppActive: { true })

        let started = Date()
        let result = await service.handleNodeCommand("photos.latest", paramsJSON: "{}", timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "Looking through your photos took too long"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "waited well past the deadline")
    }

    func testAnUnansweredPermissionPromptTimesOut() async {
        let library = StubPhotoLibrary(access: .notDetermined, items: [])
        library.delayNanoseconds = 2_000_000_000
        let service = ForegroundPhotosService(library: library, isAppActive: { true })

        let result = await service.handleNodeCommand("photos.latest", paramsJSON: "{}", timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(
            code: "TIMEOUT", message: "Photos permission was not answered in time"))
        XCTAssertEqual(library.searchCount, 0, "a timed-out prompt must not fall through to a read")
    }

    func testASlowMusicSearchTimesOut() async {
        let library = StubMusicLibrary(access: .granted, hits: [])
        library.delayNanoseconds = 2_000_000_000
        let service = ForegroundMusicService(library: library, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "music.search", paramsJSON: #"{"query":"a"}"#, timeoutMilliseconds: 50)

        XCTAssertEqual(result, .failure(code: "TIMEOUT", message: "Searching your music library took too long"))
    }

    // Weather is the only native capability making a network call, so it is
    // the one where a deadline matters most - and a timeout has to be
    // distinguishable from the backend simply failing.
    func testWeatherDistinguishesATimeoutFromAFailure() async {
        var slow = StubWeatherSource(reading: .init(
            temperatureCelsius: 1, apparentCelsius: nil, condition: "Clear",
            humidity: nil, windKilometresPerHour: nil, highCelsius: nil, lowCelsius: nil, attribution: weatherAttribution))
        slow.delayNanoseconds = 2_000_000_000

        let timedOut = await ForegroundWeatherService(source: slow, recordCard: { _ in }).handleNodeCommand(
            "weather.forecast", paramsJSON: #"{"latitude":0,"longitude":0}"#, timeoutMilliseconds: 50)
        XCTAssertEqual(timedOut, .failure(code: "TIMEOUT", message: "The forecast took too long to arrive"))

        let failed = await ForegroundWeatherService(source: StubWeatherSource(reading: nil), recordCard: { _ in }).handleNodeCommand(
            "weather.forecast", paramsJSON: #"{"latitude":0,"longitude":0}"#, timeoutMilliseconds: 5_000)
        XCTAssertEqual(failed, .failure(code: "WEATHER_UNAVAILABLE", message: "Operator could not read the forecast"))
    }

    func testAnAbsentDeadlineStillCompletesNormally() async {
        let service = ForegroundMusicService(
            library: StubMusicLibrary(access: .granted, now: .init(track: nil, isPlaying: false)),
            isAppActive: { true })

        let result = await service.handleNodeCommand("music.nowPlaying", paramsJSON: "{}", timeoutMilliseconds: nil)

        guard case .success = result else { return XCTFail("a nil deadline must mean the default, not zero") }
    }
}

// MARK: - Number parsing

final class JSONNumberTests: XCTestCase {
    // JSONSerialization bridges 0 and 1 to an NSNumber that satisfies
    // `is Bool`, so the obvious guard against {"limit": true} also rejects
    // {"limit": 1}. Two shipped connectors refused a limit of exactly one
    // before this was caught.
    func testZeroAndOneAreNumbersNotBooleans() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"a":0,"b":1,"c":2,"d":true,"e":1.5}"#.utf8)) as? [String: Any])
        XCTAssertEqual(JSONNumber.integer(object["a"]!), 0)
        XCTAssertEqual(JSONNumber.integer(object["b"]!), 1)
        XCTAssertEqual(JSONNumber.integer(object["c"]!), 2)
        XCTAssertNil(JSONNumber.integer(object["d"]!), "true is not a number")
        XCTAssertNil(JSONNumber.integer(object["e"]!), "1.5 is not a whole number")
        XCTAssertTrue(JSONNumber.isBoolean(object["d"]!))
        XCTAssertFalse(JSONNumber.isBoolean(object["a"]!))
        XCTAssertEqual(JSONNumber.integer(object["b"]!, in: 1 ... 5), 1)
        XCTAssertNil(JSONNumber.integer(object["c"]!, in: 3 ... 5))
    }

    @MainActor
    func testEveryLimitAcceptsOneAndStillRefusesBooleans() {
        XCTAssertEqual(ForegroundRemindersService.limit(from: #"{"limit":1}"#), 1)
        XCTAssertEqual(ForegroundRemindersService.limit(from: #"{"limit":25}"#), 25)
        XCTAssertNil(ForegroundRemindersService.limit(from: #"{"limit":0}"#))
        XCTAssertNil(ForegroundRemindersService.limit(from: #"{"limit":true}"#))
        XCTAssertEqual(ForegroundContactsService.request(from: #"{"query":"a","limit":1}"#)?.limit, 1)
        XCTAssertNil(ForegroundContactsService.request(from: #"{"query":"a","limit":true}"#))
        XCTAssertEqual(ForegroundPhotosService.request(from: #"{"limit":1}"#)?.limit, 1)
        XCTAssertNil(ForegroundPhotosService.request(from: #"{"limit":true}"#))
        XCTAssertEqual(ForegroundMusicService.searchRequest(from: #"{"query":"a","limit":1}"#)?.1, 1)
        XCTAssertNil(ForegroundMusicService.searchRequest(from: #"{"query":"a","limit":true}"#))
    }
}

// MARK: - Stubs

@MainActor
private final class StubPhotoLibrary: PhotoLibrary {
    var access: PhotosAccess
    private(set) var searchCount = 0
    private(set) var lastAlbum: String?
    private(set) var lastFrom: Date?
    private(set) var lastTo: Date?
    private(set) var lastLimit: Int?
    private let items: [PhotoItem]

    var delayNanoseconds: UInt64 = 0

    init(access: PhotosAccess, items: [PhotoItem]) { self.access = access; self.items = items }
    func requestAccess() async -> Bool {
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        self.access = .full
        return true
    }
    func search(album: String?, from: Date?, to: Date?, limit: Int) async -> [PhotoItem] {
        self.searchCount += 1
        self.lastAlbum = album; self.lastFrom = from; self.lastTo = to; self.lastLimit = limit
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        return self.items  // deliberately ignores the limit
    }
}

@MainActor
private final class StubMusicLibrary: MusicLibrary {
    var access: MusicAccess
    private(set) var searchCount = 0
    private let now: NowPlaying
    private let hits: [MusicTrack]

    init(access: MusicAccess, now: NowPlaying = .init(track: nil, isPlaying: false), hits: [MusicTrack] = []) {
        self.access = access; self.now = now; self.hits = hits
    }
    var delayNanoseconds: UInt64 = 0

    func requestAccess() async -> Bool { self.access = .granted; return true }
    func nowPlaying() async -> NowPlaying {
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        return self.now
    }

    func search(query _: String, limit _: Int) async -> [MusicTrack] {
        self.searchCount += 1
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        return self.hits
    }
}

private let weatherAttribution = WeatherCardAttribution(legalPageURL: URL(string: "https://weather.example/legal")!, combinedMarkLightURL: URL(string: "https://weather.example/light")!, combinedMarkDarkURL: URL(string: "https://weather.example/dark")!)

private struct StubWeatherSource: WeatherSource {
    let reading: WeatherReading?
    var delayNanoseconds: UInt64 = 0
    func reading(latitude _: Double, longitude _: Double) async throws -> WeatherReading {
        if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
        guard let reading else { throw NSError(domain: "stub-backend-detail", code: 42) }
        return reading
    }
}

private actor WeatherCardRecorder {
    private var value: [WeatherCard] = []; private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func record(_ card: WeatherCard) throws { if fails { throw FixtureFailure.failed }; value.append(card) }
    func cards() -> [WeatherCard] { value }
    private enum FixtureFailure: Error { case failed }
}

@MainActor
private final class StubDeviceStatusSource: DeviceStatusSource {
    private let value: DeviceStatus
    init(_ value: DeviceStatus) { self.value = value }
    func status() -> DeviceStatus { self.value }
}

private func payloadObject(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
    guard case .success(let payloadJSON) = result else { throw XCTSkip("expected success, got \(result)") }
    guard let object = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any] else {
        throw XCTSkip("payload was not an object: \(payloadJSON)")
    }
    return object
}
