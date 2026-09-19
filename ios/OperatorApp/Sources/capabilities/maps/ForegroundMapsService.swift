import Contacts
import Foundation
@preconcurrency import MapKit
import OperatorCore
import OSLog
#if canImport(UIKit)
import UIKit
#endif

struct MapCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct MapPlace: Sendable {
    let name: String
    let address: String?
    let coordinate: MapCoordinate
}

struct MapRoute: Sendable {
    struct Step: Sendable {
        let instructions: String
        let distanceMeters: Double
    }

    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double
    let steps: [Step]
}

enum MapTransport: String, Decodable, Sendable {
    case driving
    case walking
    case transit
}

@MainActor
protocol MapsProvider: AnyObject, Sendable {
    func search(query: String, limit: Int) async throws -> [MapPlace]
    func directions(from: MapCoordinate, to: MapCoordinate, transport: MapTransport) async throws -> [MapRoute]
    func cancel()
}

@MainActor
final class ForegroundMapsService: GatewayNodeCommandHandler {
    private static let maximumResults = 10
    private static let maximumRoutes = 3
    private static let maximumSteps = 12

    private struct SearchParameters: Decodable {
        let query: String
        let limit: Int?
    }

    private struct DirectionsParameters: Decodable {
        struct Coordinate: Decodable {
            let lat: Double
            let lon: Double
        }

        let from: Coordinate
        let to: Coordinate
        let transport: MapTransport?
    }

    private struct SearchPayload: Encodable {
        struct Place: Encodable {
            let name: String
            let address: String?
            let lat: Double
            let lon: Double
        }
        let results: [Place]
    }

    private struct DirectionsPayload: Encodable {
        struct Route: Encodable {
            struct Step: Encodable {
                let instructions: String
                let distanceMeters: Double
            }
            let distanceMeters: Double
            let expectedTravelTimeSeconds: Double
            let steps: [Step]
        }
        let routes: [Route]
    }

    private let provider: any MapsProvider
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-maps")

    convenience init() { self.init(provider: MapKitMapsProvider()) }

    init(
        provider: any MapsProvider,
        isAppActive: @escaping @MainActor @Sendable () -> Bool = {
            #if canImport(UIKit)
            UIApplication.shared.applicationState == .active
            #else
            true
            #endif
        })
    {
        self.provider = provider
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "maps.search" || command == "maps.directions" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard self.isAppActive() else {
            self.logger.info("[maps] rejected request while app was not active command=\(command, privacy: .public)")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use Maps")
        }

        switch command {
        case "maps.search":
            guard let parameters = Self.searchParameters(from: paramsJSON) else {
                return .failure(code: "INVALID_REQUEST", message: "Map parameters were invalid")
            }
            return await self.performSearch(parameters)
        case "maps.directions":
            guard let parameters = Self.directionsParameters(from: paramsJSON) else {
                return .failure(code: "INVALID_REQUEST", message: "Map parameters were invalid")
            }
            return await self.performDirections(parameters)
        default:
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
    }

    private func performSearch(_ parameters: SearchParameters) async -> GatewayNodeCommandResult {
        let limit = parameters.limit ?? Self.maximumResults
        self.logger.info("[maps] accepted search limit=\(limit)")
        do {
            let places = try await self.withCancellation { provider in
                try await provider.search(query: parameters.query, limit: limit)
            }
            guard self.isAppActive() else {
                self.logger.info("[maps] discarded search result after app left foreground")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use Maps")
            }
            let payload = SearchPayload(results: places.prefix(limit).map {
                .init(name: $0.name, address: $0.address, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
            })
            return self.encoded(payload, action: "search", count: payload.results.count)
        } catch is CancellationError {
            self.logger.info("[maps] search cancelled")
            return .failure(code: "CANCELLED", message: "Map request was cancelled")
        } catch {
            self.logger.error("[maps] search failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return .failure(code: "MAPS_UNAVAILABLE", message: "Maps could not complete this request")
        }
    }

    private func performDirections(_ parameters: DirectionsParameters) async -> GatewayNodeCommandResult {
        let from = MapCoordinate(latitude: parameters.from.lat, longitude: parameters.from.lon)
        let to = MapCoordinate(latitude: parameters.to.lat, longitude: parameters.to.lon)
        let transport = parameters.transport ?? .driving
        self.logger.info("[maps] accepted directions transport=\(transport.rawValue, privacy: .public)")
        do {
            let routes = try await self.withCancellation { provider in
                try await provider.directions(from: from, to: to, transport: transport)
            }
            guard self.isAppActive() else {
                self.logger.info("[maps] discarded directions result after app left foreground")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use Maps")
            }
            let payload = DirectionsPayload(routes: routes.prefix(Self.maximumRoutes).map { route in
                .init(
                    distanceMeters: route.distanceMeters,
                    expectedTravelTimeSeconds: route.expectedTravelTimeSeconds,
                    steps: route.steps.prefix(Self.maximumSteps).map {
                        .init(instructions: $0.instructions, distanceMeters: $0.distanceMeters)
                    })
            })
            return self.encoded(payload, action: "directions", count: payload.routes.count)
        } catch is CancellationError {
            self.logger.info("[maps] directions cancelled")
            return .failure(code: "CANCELLED", message: "Map request was cancelled")
        } catch {
            self.logger.error("[maps] directions failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return .failure(code: "MAPS_UNAVAILABLE", message: "Maps could not complete this request")
        }
    }

    private func withCancellation<Result: Sendable>(
        _ operation: @escaping @MainActor @Sendable (any MapsProvider) async throws -> Result) async throws -> Result
    {
        try await withTaskCancellationHandler(operation: {
            try await operation(self.provider)
        }, onCancel: { [provider] in
            Task { @MainActor in provider.cancel() }
        })
    }

    private func encoded<Payload: Encodable>(_ payload: Payload, action: String, count: Int) -> GatewayNodeCommandResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[maps] failed to encode \(action, privacy: .public) result")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not encode map results")
        }
        self.logger.info("[maps] returned \(action, privacy: .public) count=\(count)")
        return .success(payloadJSON: payloadJSON)
    }

    private static func searchParameters(from json: String?) -> SearchParameters? {
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              Set(object.keys).isSubset(of: ["query", "limit"]),
              let parameters = try? JSONDecoder().decode(SearchParameters.self, from: Data(json.utf8)),
              !parameters.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              parameters.query.count <= 200,
              parameters.limit.map({ (1 ... Self.maximumResults).contains($0) }) ?? true
        else { return nil }
        return parameters
    }

    private static func directionsParameters(from json: String?) -> DirectionsParameters? {
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              Set(object.keys).isSubset(of: ["from", "to", "transport"]),
              let from = object["from"] as? [String: Any],
              let to = object["to"] as? [String: Any],
              Set(from.keys) == Set(["lat", "lon"]),
              Set(to.keys) == Set(["lat", "lon"]),
              let parameters = try? JSONDecoder().decode(DirectionsParameters.self, from: Data(json.utf8)),
              Self.coordinateIsValid(parameters.from), Self.coordinateIsValid(parameters.to)
        else { return nil }
        return parameters
    }

    private static func coordinateIsValid(_ coordinate: DirectionsParameters.Coordinate) -> Bool {
        coordinate.lat.isFinite && coordinate.lon.isFinite
            && (-90 ... 90).contains(coordinate.lat)
            && (-180 ... 180).contains(coordinate.lon)
    }
}

@MainActor
private final class MapKitMapsProvider: MapsProvider {
    private var activeSearch: MKLocalSearch?
    private var activeDirections: MKDirections?

    func search(query: String, limit _: Int) async throws -> [MapPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)
        self.activeSearch = search
        defer { self.activeSearch = nil }
        let response = try await search.start()
        return response.mapItems.compactMap { item in
            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate), let name = item.name, !name.isEmpty else { return nil }
            let address = item.placemark.postalAddress.map {
                CNPostalAddressFormatter.string(from: $0, style: .mailingAddress)
            }.flatMap { $0.isEmpty ? nil : $0 }
            return MapPlace(name: name, address: address, coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }

    func directions(from: MapCoordinate, to: MapCoordinate, transport: MapTransport) async throws -> [MapRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: from.latitude, longitude: from.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: to.latitude, longitude: to.longitude)))
        request.transportType = switch transport {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
        request.requestsAlternateRoutes = true
        let directions = MKDirections(request: request)
        self.activeDirections = directions
        defer { self.activeDirections = nil }
        let response = try await directions.calculate()
        return response.routes.map { route in
            .init(distanceMeters: route.distance, expectedTravelTimeSeconds: route.expectedTravelTime, steps: route.steps.map {
                .init(instructions: $0.instructions, distanceMeters: $0.distance)
            })
        }
    }

    func cancel() {
        self.activeSearch?.cancel()
        self.activeDirections?.cancel()
    }
}
