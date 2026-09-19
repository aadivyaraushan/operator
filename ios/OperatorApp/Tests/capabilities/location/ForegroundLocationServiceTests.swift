import CoreLocation
import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundLocationServiceTests: XCTestCase {
    func testDeniedPermissionFailsWithoutStartingLocation() async {
        let manager = RecordingLocationManager(authorization: .denied)
        let service = ForegroundLocationService(manager: manager, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "location.get",
            paramsJSON: "{}",
            timeoutMilliseconds: 10_000)

        XCTAssertEqual(
            result,
            .failure(code: "PERMISSION_DENIED", message: "Location permission was denied"))
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.locationRequests, 0)
    }

    func testInactiveAppFailsBeforeRequestingPermission() async {
        let manager = RecordingLocationManager(authorization: .notDetermined)
        let service = ForegroundLocationService(manager: manager, isAppActive: { false })

        let result = await service.handleNodeCommand(
            "location.get",
            paramsJSON: "{}",
            timeoutMilliseconds: 10_000)

        XCTAssertEqual(
            result,
            .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to share your location"))
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.locationRequests, 0)
    }

    func testAuthorizationThenOneShotLocationReturnsCanonicalPayload() async throws {
        let manager = RecordingLocationManager(authorization: .notDetermined, precision: .full)
        let service = ForegroundLocationService(manager: manager, isAppActive: { true })
        let timestamp = Date()
        let task = Task {
            await service.handleNodeCommand(
                "location.get",
                paramsJSON: #"{"desiredAccuracy":"precise","maxAgeMs":5000,"timeoutMs":8000}"#,
                timeoutMilliseconds: 10_000)
        }

        await waitUntil { manager.authorizationRequests == 1 }
        manager.authorize()
        await waitUntil { manager.locationRequests == 1 }
        manager.deliver(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.1106, longitude: -88.2073),
            altitude: 0,
            horizontalAccuracy: 12.5,
            verticalAccuracy: -1,
            timestamp: timestamp))
        let result = await task.value

        guard case let .success(payloadJSON) = result else {
            return XCTFail("Expected a successful location result")
        }
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
        let latitude = try XCTUnwrap(payload["lat"] as? Double)
        let longitude = try XCTUnwrap(payload["lon"] as? Double)
        XCTAssertEqual(latitude, 40.1106, accuracy: 0.000_001)
        XCTAssertEqual(longitude, -88.2073, accuracy: 0.000_001)
        XCTAssertEqual(payload["accuracyMeters"] as? Double, 12.5)
        XCTAssertEqual(payload["isPrecise"] as? Bool, true)
        XCTAssertEqual(
            payload["timestamp"] as? String,
            ISO8601DateFormatter().string(from: timestamp))
        XCTAssertEqual(manager.desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(manager.locationRequests, 1)
    }

    func testLocationFailureCompletesOnceWithUnavailableError() async {
        let manager = RecordingLocationManager(authorization: .authorized, precision: .reduced)
        let service = ForegroundLocationService(manager: manager, isAppActive: { true })
        let task = Task {
            await service.handleNodeCommand(
                "location.get",
                paramsJSON: "{}",
                timeoutMilliseconds: 10_000)
        }

        await waitUntil { manager.locationRequests == 1 }
        manager.fail()
        manager.fail()
        let result = await task.value

        XCTAssertEqual(
            result,
            .failure(code: "LOCATION_UNAVAILABLE", message: "Current location is unavailable"))
    }

    func testLocationIsNotReturnedAfterAppMovesOutOfForeground() async {
        let manager = RecordingLocationManager(authorization: .authorized)
        let activity = AppActivityState(isActive: true)
        let service = ForegroundLocationService(
            manager: manager,
            isAppActive: { activity.isActive })
        let task = Task {
            await service.handleNodeCommand(
                "location.get",
                paramsJSON: "{}",
                timeoutMilliseconds: 10_000)
        }

        await waitUntil { manager.locationRequests == 1 }
        activity.isActive = false
        manager.deliver(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.1106, longitude: -88.2073),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            timestamp: Date()))
        let result = await task.value

        XCTAssertEqual(
            result,
            .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to share your location"))
    }

    func testTimeoutIsBoundedByTheGatewayDeadline() async {
        let manager = RecordingLocationManager(authorization: .authorized)
        var observedTimeout: Duration?
        let service = ForegroundLocationService(
            manager: manager,
            isAppActive: { true },
            waitForTimeout: { duration in
                observedTimeout = duration
            })

        let result = await service.handleNodeCommand(
            "location.get",
            paramsJSON: #"{"timeoutMs":30000}"#,
            timeoutMilliseconds: 4_000)

        XCTAssertEqual(observedTimeout, .milliseconds(4_000))
        XCTAssertEqual(
            result,
            .failure(code: "TIMEOUT", message: "Location request timed out"))
        XCTAssertEqual(manager.locationRequests, 1)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool) async
    {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            await Task.yield()
        }
    }
}

@MainActor
private final class AppActivityState {
    var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }
}

@MainActor
private final class RecordingLocationManager: OneShotLocationManaging {
    weak var delegate: (any OneShotLocationManagerDelegate)?
    var authorization: OneShotLocationAuthorization
    let precision: OneShotLocationPrecision
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters
    private(set) var authorizationRequests = 0
    private(set) var locationRequests = 0

    init(
        authorization: OneShotLocationAuthorization,
        precision: OneShotLocationPrecision = .full)
    {
        self.authorization = authorization
        self.precision = precision
    }

    func requestWhenInUseAuthorization() {
        self.authorizationRequests += 1
    }

    func requestLocation() {
        self.locationRequests += 1
    }

    func authorize() {
        self.authorization = .authorized
        self.delegate?.locationAuthorizationDidChange()
    }

    func deliver(_ location: CLLocation) {
        self.delegate?.locationDidUpdate([location])
    }

    func fail() {
        self.delegate?.locationDidFail()
    }
}
