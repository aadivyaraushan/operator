import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundMapsServiceTests: XCTestCase {
    func testSearchReturnsOnlyBoundedCanonicalPlaces() async throws {
        let maps = RecordingMapsProvider(searchResults: [
            .init(name: "Cafe", address: "1 Main St", coordinate: .init(latitude: 40.1, longitude: -88.2)),
            .init(name: "Library", address: nil, coordinate: .init(latitude: 40.2, longitude: -88.3)),
            .init(name: "Park", address: nil, coordinate: .init(latitude: 40.3, longitude: -88.4)),
        ])
        let service = ForegroundMapsService(provider: maps, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "maps.search", paramsJSON: #"{"query":"coffee","limit":2}"#, timeoutMilliseconds: 10_000)

        XCTAssertEqual(maps.searchCalls, 1)
        XCTAssertEqual(maps.lastSearchLimit, 2)
        let places = try XCTUnwrap(try payload(result)["results"] as? [[String: Any]])
        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places[0]["name"] as? String, "Cafe")
        XCTAssertEqual(places[0]["lat"] as? Double, 40.1)
        XCTAssertEqual(places[0]["lon"] as? Double, -88.2)
        XCTAssertNil(places[1]["address"])
    }

    func testDirectionsReturnsBoundedRoutesAndSteps() async throws {
        let maps = RecordingMapsProvider(directionResults: [
            .init(distanceMeters: 1234, expectedTravelTimeSeconds: 456, steps: (0 ..< 15).map {
                .init(instructions: "Step \($0)", distanceMeters: Double($0))
            }),
            .init(distanceMeters: 2345, expectedTravelTimeSeconds: 567, steps: []),
            .init(distanceMeters: 3456, expectedTravelTimeSeconds: 678, steps: []),
            .init(distanceMeters: 4567, expectedTravelTimeSeconds: 789, steps: []),
        ])
        let service = ForegroundMapsService(provider: maps, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "maps.directions",
            paramsJSON: #"{"from":{"lat":40.1,"lon":-88.2},"to":{"lat":40.2,"lon":-88.3},"transport":"walking"}"#,
            timeoutMilliseconds: 10_000)

        XCTAssertEqual(maps.directionsCalls, 1)
        XCTAssertEqual(maps.lastTransport, .walking)
        let routes = try XCTUnwrap(try payload(result)["routes"] as? [[String: Any]])
        XCTAssertEqual(routes.count, 3)
        let steps = try XCTUnwrap(routes[0]["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 12)
        XCTAssertEqual(steps.first?["instructions"] as? String, "Step 0")
    }

    func testInvalidRequestsNeverReachMaps() async {
        let invalid: [(String, String?)] = [
            ("maps.search", nil), ("maps.search", #"{"query":" "}"#),
            ("maps.search", #"{"query":"coffee","limit":11}"#),
            ("maps.search", #"{"query":"coffee","extra":true}"#),
            ("maps.directions", #"{"from":{"lat":91,"lon":0},"to":{"lat":0,"lon":0}}"#),
            ("maps.directions", #"{"from":{"lat":0,"lon":0},"to":{"lat":0,"lon":0},"transport":"flying"}"#),
            ("maps.directions", #"{"from":{"lat":0,"lon":0,"alt":5},"to":{"lat":0,"lon":0}}"#),
            ("maps.directions", #"{"from":{"lat":0,"lon":0},"to":{"lat":0,"lon":0},"extra":true}"#),
        ]
        for (command, params) in invalid {
            let maps = RecordingMapsProvider()
            let service = ForegroundMapsService(provider: maps, isAppActive: { true })
            let result = await service.handleNodeCommand(command, paramsJSON: params, timeoutMilliseconds: nil)
            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "Map parameters were invalid"))
            XCTAssertEqual(maps.searchCalls + maps.directionsCalls, 0)
        }
    }

    func testInactiveAppDoesNotUseMaps() async {
        let maps = RecordingMapsProvider()
        let service = ForegroundMapsService(provider: maps, isAppActive: { false })

        let result = await service.handleNodeCommand("maps.search", paramsJSON: #"{"query":"coffee"}"#, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use Maps"))
        XCTAssertEqual(maps.searchCalls + maps.directionsCalls, 0)
    }

    func testCancellationCancelsTheActiveNativeMapRequest() async {
        let maps = BlockingMapsProvider()
        let service = ForegroundMapsService(provider: maps, isAppActive: { true })
        let task = Task {
            await service.handleNodeCommand("maps.search", paramsJSON: #"{"query":"coffee"}"#, timeoutMilliseconds: nil)
        }

        await self.waitUntil { maps.searchCalls == 1 }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(code: "CANCELLED", message: "Map request was cancelled"))
        XCTAssertEqual(maps.cancelCalls, 1)
    }

    func testRouterForwardsMapsCommandsOnlyToMapsHandler() async {
        let location = RecordingMapsNodeHandler()
        let calendar = RecordingMapsNodeHandler()
        let messages = RecordingMapsNodeHandler()
        let maps = RecordingMapsNodeHandler(result: .success(payloadJSON: #"{"results":[]}"#))
        let router = ForegroundNodeCommandRouter(location: location, calendar: calendar, messages: messages, maps: maps, handoff: RecordingMapsNodeHandler(), whatsapp: RecordingMapsNodeHandler(), whatsappCompose: RecordingMapsNodeHandler(), accounts: RecordingMapsNodeHandler(), accountWrite: RecordingMapsNodeHandler(), notion: RecordingMapsNodeHandler())

        let result = await router.handleNodeCommand("maps.search", paramsJSON: #"{"query":"coffee"}"#, timeoutMilliseconds: 6_000)

        XCTAssertEqual(result, .success(payloadJSON: #"{"results":[]}"#))
        XCTAssertEqual(maps.invocations, [.init(command: "maps.search", paramsJSON: #"{"query":"coffee"}"#, timeoutMilliseconds: 6_000)])
        XCTAssertTrue(location.invocations.isEmpty)
        XCTAssertTrue(calendar.invocations.isEmpty)
        XCTAssertTrue(messages.invocations.isEmpty)
    }

    private func payload(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case let .success(payloadJSON) = result else { throw NSError(domain: "test", code: 1) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(1)
        while !condition(), Date() < end { await Task.yield() }
    }
}

@MainActor
private final class RecordingMapsProvider: MapsProvider {
    var searchResults: [MapPlace]
    var directionResults: [MapRoute]
    private(set) var searchCalls = 0
    private(set) var directionsCalls = 0
    private(set) var lastSearchLimit: Int?
    private(set) var lastTransport: MapTransport?

    init(searchResults: [MapPlace] = [], directionResults: [MapRoute] = []) {
        self.searchResults = searchResults
        self.directionResults = directionResults
    }

    func search(query _: String, limit: Int) async throws -> [MapPlace] {
        self.searchCalls += 1
        self.lastSearchLimit = limit
        return self.searchResults
    }

    func directions(from _: MapCoordinate, to _: MapCoordinate, transport: MapTransport) async throws -> [MapRoute] {
        self.directionsCalls += 1
        self.lastTransport = transport
        return self.directionResults
    }

    func cancel() {}
}

@MainActor
private final class BlockingMapsProvider: MapsProvider {
    private(set) var searchCalls = 0
    private(set) var cancelCalls = 0

    func search(query _: String, limit _: Int) async throws -> [MapPlace] {
        self.searchCalls += 1
        try await Task.sleep(for: .seconds(10))
        return []
    }

    func directions(from _: MapCoordinate, to _: MapCoordinate, transport _: MapTransport) async throws -> [MapRoute] { [] }
    func cancel() { self.cancelCalls += 1 }
}

private struct RecordedMapsInvocation: Equatable {
    let command: String
    let paramsJSON: String?
    let timeoutMilliseconds: Int?
}

@MainActor
private final class RecordingMapsNodeHandler: GatewayNodeCommandHandler {
    let result: GatewayNodeCommandResult
    private(set) var invocations: [RecordedMapsInvocation] = []
    init(result: GatewayNodeCommandResult = .success(payloadJSON: "{}")) { self.result = result }
    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        self.invocations.append(.init(command: command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds))
        return self.result
    }
}
