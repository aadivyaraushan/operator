import Foundation
import XCTest
@testable import OperatorCore

/// The websocket carries the chat stream and the native node for as long as
/// the app is in the foreground. Capping the task's total lifetime killed it
/// on a timer, which read as the phone randomly disconnecting rather than as
/// a timeout, so it is asserted rather than left to a comment.
final class GatewayWebSocketTransportConfigurationTests: XCTestCase {
    func testTotalTaskLifetimeIsNotCapped() {
        let configuration = URLSessionGatewayTransport.configuration(handshakeTimeout: 30)
        // URLSession's default is seven days. Anything near the handshake
        // timeout means the socket is on a countdown from the moment it opens.
        XCTAssertGreaterThan(
            configuration.timeoutIntervalForResource, 3600,
            "a resource timeout this short disconnects a healthy websocket on a timer")
    }

    func testHandshakeStillHasADeadline() {
        let configuration = URLSessionGatewayTransport.configuration(handshakeTimeout: 12)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 12)
    }

    func testWaitsForConnectivitySoALaunchBeforeTheNetworkStillConnects() {
        XCTAssertTrue(URLSessionGatewayTransport.configuration(handshakeTimeout: 30).waitsForConnectivity)
    }
}
