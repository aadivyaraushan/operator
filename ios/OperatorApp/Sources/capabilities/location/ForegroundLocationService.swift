import CoreLocation
import Foundation
import OperatorCore
import OSLog
import UIKit

enum OneShotLocationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

enum OneShotLocationPrecision: Equatable, Sendable {
    case full
    case reduced
}

@MainActor
protocol OneShotLocationManagerDelegate: AnyObject {
    func locationAuthorizationDidChange()
    func locationDidUpdate(_ locations: [CLLocation])
    func locationDidFail()
}

@MainActor
protocol OneShotLocationManaging: AnyObject {
    var delegate: (any OneShotLocationManagerDelegate)? { get set }
    var authorization: OneShotLocationAuthorization { get }
    var precision: OneShotLocationPrecision { get }
    var desiredAccuracy: CLLocationAccuracy { get set }

    func requestWhenInUseAuthorization()
    func requestLocation()
}

@MainActor
final class ForegroundLocationService: GatewayNodeCommandHandler, OneShotLocationManagerDelegate {
    private struct RequestParameters: Decodable {
        enum DesiredAccuracy: String, Decodable {
            case coarse
            case balanced
            case precise
        }

        let maxAgeMs: Int?
        let desiredAccuracy: DesiredAccuracy?
        let timeoutMs: Int?
    }

    private struct Payload: Encodable {
        let lat: Double
        let lon: Double
        let accuracyMeters: Double
        let timestamp: String
        let isPrecise: Bool
    }

    private struct PendingRequest {
        let parameters: RequestParameters
        let continuation: CheckedContinuation<GatewayNodeCommandResult, Never>
    }

    private let manager: any OneShotLocationManaging
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let waitForTimeout: @MainActor @Sendable (Duration) async -> Void
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-location")
    private var pending: PendingRequest?
    private var timeoutTask: Task<Void, Never>?

    convenience init() {
        self.init(manager: CoreLocationOneShotManager())
    }

    init(
        manager: any OneShotLocationManaging,
        isAppActive: @escaping @MainActor @Sendable () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        waitForTimeout: @escaping @MainActor @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        })
    {
        self.manager = manager
        self.isAppActive = isAppActive
        self.waitForTimeout = waitForTimeout
        self.manager.delegate = self
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "location.get" else {
            return .failure(
                code: "UNSUPPORTED_COMMAND",
                message: "This iPhone node does not support \(command)")
        }
        guard self.pending == nil else {
            return .failure(code: "BUSY", message: "A location request is already active")
        }
        guard self.isAppActive() else {
            self.logger.info("[location] rejected request while app was not active")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to share your location")
        }
        guard let parameters = Self.decodeParameters(paramsJSON),
              Self.parametersAreValid(parameters)
        else {
            return .failure(code: "INVALID_REQUEST", message: "Location parameters were invalid")
        }
        guard self.manager.authorization != .denied else {
            self.logger.info("[location] permission already denied")
            return .failure(code: "PERMISSION_DENIED", message: "Location permission was denied")
        }

        self.manager.desiredAccuracy = Self.coreLocationAccuracy(parameters.desiredAccuracy)
        let timeout = Self.boundedTimeout(
            requestedMilliseconds: parameters.timeoutMs,
            gatewayMilliseconds: timeoutMilliseconds)
        self.logger.info(
            "[location] request accepted permission=\(String(describing: self.manager.authorization), privacy: .public) timeoutMs=\(timeout)")

        return await withCheckedContinuation { continuation in
            self.pending = PendingRequest(parameters: parameters, continuation: continuation)
            self.timeoutTask = Task { [weak self, waitForTimeout = self.waitForTimeout] in
                await waitForTimeout(.milliseconds(timeout))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(code: "TIMEOUT", message: "Location request timed out"))
            }
            self.continueAfterAuthorizationCheck()
        }
    }

    func locationAuthorizationDidChange() {
        guard self.pending != nil else { return }
        self.continueAfterAuthorizationCheck()
    }

    func locationDidUpdate(_ locations: [CLLocation]) {
        guard let pending = self.pending else { return }
        guard self.isAppActive() else {
            self.logger.info("[location] discarded location fix after app left foreground")
            self.finish(.failure(
                code: "APP_NOT_ACTIVE",
                message: "Open Operator to share your location"))
            return
        }
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }),
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0
        else {
            self.finish(.failure(
                code: "LOCATION_UNAVAILABLE",
                message: "Current location is unavailable"))
            return
        }
        if let maxAgeMs = pending.parameters.maxAgeMs,
           Date().timeIntervalSince(location.timestamp) * 1_000 > Double(maxAgeMs)
        {
            self.logger.info("[location] location fix was older than requested maxAgeMs")
            self.finish(.failure(
                code: "LOCATION_UNAVAILABLE",
                message: "Current location is unavailable"))
            return
        }

        let payload = Payload(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy,
            timestamp: ISO8601DateFormatter().string(from: location.timestamp),
            isPrecise: self.manager.precision == .full)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[location] failed to encode location result")
            self.finish(.failure(code: "INTERNAL_ERROR", message: "Operator could not encode location"))
            return
        }
        self.logger.info("[location] returning one location fix without logging coordinates")
        self.finish(.success(payloadJSON: payloadJSON))
    }

    func locationDidFail() {
        guard self.pending != nil else { return }
        self.logger.info("[location] Core Location did not return a fix")
        self.finish(.failure(
            code: "LOCATION_UNAVAILABLE",
            message: "Current location is unavailable"))
    }

    private func continueAfterAuthorizationCheck() {
        switch self.manager.authorization {
        case .notDetermined:
            self.logger.info("[location] requesting When In Use permission")
            self.manager.requestWhenInUseAuthorization()
        case .authorized:
            self.logger.info("[location] requesting one location fix")
            self.manager.requestLocation()
        case .denied:
            self.finish(.failure(code: "PERMISSION_DENIED", message: "Location permission was denied"))
        }
    }

    private func finish(_ result: GatewayNodeCommandResult) {
        guard let pending = self.pending else { return }
        self.pending = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        pending.continuation.resume(returning: result)
    }

    private static func decodeParameters(_ paramsJSON: String?) -> RequestParameters? {
        try? JSONDecoder().decode(RequestParameters.self, from: Data((paramsJSON ?? "{}").utf8))
    }

    private static func parametersAreValid(_ parameters: RequestParameters) -> Bool {
        if let maxAgeMs = parameters.maxAgeMs, maxAgeMs < 0 { return false }
        if let timeoutMs = parameters.timeoutMs, timeoutMs <= 0 { return false }
        return true
    }

    private static func boundedTimeout(
        requestedMilliseconds: Int?,
        gatewayMilliseconds: Int?) -> Int
    {
        let requested = min(max(requestedMilliseconds ?? 10_000, 1), 30_000)
        let gateway = min(max(gatewayMilliseconds ?? 20_000, 1), 30_000)
        return min(requested, gateway)
    }

    private static func coreLocationAccuracy(
        _ accuracy: RequestParameters.DesiredAccuracy?) -> CLLocationAccuracy
    {
        switch accuracy {
        case .coarse: kCLLocationAccuracyKilometer
        case .balanced, .none: kCLLocationAccuracyHundredMeters
        case .precise: kCLLocationAccuracyBest
        }
    }
}

@MainActor
private final class CoreLocationOneShotManager: NSObject, OneShotLocationManaging,
    @preconcurrency CLLocationManagerDelegate
{
    weak var delegate: (any OneShotLocationManagerDelegate)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        self.manager.delegate = self
    }

    var authorization: OneShotLocationAuthorization {
        switch self.manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    var precision: OneShotLocationPrecision {
        self.manager.accuracyAuthorization == .fullAccuracy ? .full : .reduced
    }

    var desiredAccuracy: CLLocationAccuracy {
        get { self.manager.desiredAccuracy }
        set { self.manager.desiredAccuracy = newValue }
    }

    func requestWhenInUseAuthorization() {
        self.manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        self.manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.delegate?.locationAuthorizationDidChange()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        self.delegate?.locationDidUpdate(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        self.delegate?.locationDidFail()
    }
}
