import Foundation
import XCTest
@testable import OperatorCore

/// The gateway restarts after the app patches its config. A socket opened at
/// that moment is accepted by the listener and then hears nothing: no
/// challenge ever comes. Both connections waited on it forever, so the phone
/// node never re-registered ("iPhone node is disconnected") until relaunch.
final class GatewayHandshakeDeadlineTests: XCTestCase {
    func testAChatConnectionGivesUpWhenTheChallengeNeverArrives() async throws {
        let transport = SilentGatewayTransport()
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS 18.5.0", instanceID: "install-1"),
            handshakeTimeoutMilliseconds: 50)

        let started = Date()
        do {
            try await connection.connect()
            XCTFail("connect should not succeed")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error, .handshakeTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let closed = await transport.wasClosed()
        let connected = await connection.isConnected
        XCTAssertTrue(closed)
        XCTAssertFalse(connected)
    }

    func testANodeConnectionGivesUpWhenTheChallengeNeverArrives() async throws {
        let transport = SilentGatewayTransport()
        let connection = OpenClawNodeConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            appVersion: "1.0",
            handshakeTimeoutMilliseconds: 50)

        let started = Date()
        do {
            try await connection.connect()
            XCTFail("connect should not succeed")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error, .handshakeTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let closed = await transport.wasClosed()
        let connected = await connection.isConnected
        XCTAssertTrue(closed)
        XCTAssertFalse(connected)
    }
}

/// Opens fine, accepts sends, and never delivers a frame.
private actor SilentGatewayTransport: GatewayTransport {
    private var closed = false

    func open() async throws {}

    func send(_ data: Data) async throws {}

    func receive() async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waiting.append(continuation)
                }
            }
        }, onCancel: {
            Task { await self.cancelAll() }
        })
    }

    func close() async {
        self.closed = true
        self.cancelAll()
    }

    func wasClosed() -> Bool { self.closed }

    private var waiting: [CheckedContinuation<Data, Error>] = []

    private func cancelAll() {
        let waiters = self.waiting
        self.waiting.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
}
