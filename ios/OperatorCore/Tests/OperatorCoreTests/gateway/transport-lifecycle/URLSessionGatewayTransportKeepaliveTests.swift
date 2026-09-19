import Foundation
import XCTest
@testable import OperatorCore

#if os(macOS)
final class URLSessionGatewayTransportKeepaliveTests: XCTestCase {
    func testSocketRemainsWritableAfterGatewayPingCadenceWithoutCallerReceive() async throws {
        let server = try await LocalGatewayWebSocketServer(mode: "keepalive")
        defer { server.stop() }
        let transport = URLSessionGatewayTransport(url: server.url)
        try await transport.open()
        try await server.waitForHandshake()

        try await Task.sleep(for: .seconds(76))
        try await transport.send(Data("after-75-second-ping-window".utf8))

        let text = try await server.waitForText()
        let pongs = await server.pongCount
        XCTAssertEqual(text, "after-75-second-ping-window")
        XCTAssertEqual(pongs, 3)
        await transport.close()
    }

    func testReceivePreservesWireOrder() async throws {
        let server = try await LocalGatewayWebSocketServer(mode: "sequence")
        defer { server.stop() }
        let transport = URLSessionGatewayTransport(url: server.url)
        try await transport.open()

        let first = try await transport.receive()
        let second = try await transport.receive()

        XCTAssertEqual(String(decoding: first, as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "second")
        await transport.close()
    }

    func testCloseThenOpenDropsOldSocketFrames() async throws {
        let server = try await LocalGatewayWebSocketServer(mode: "reopen")
        defer { server.stop() }
        let transport = URLSessionGatewayTransport(url: server.url)
        try await transport.open()
        try await Task.sleep(for: .milliseconds(300))
        await transport.close()
        try await transport.open()

        let message = try await transport.receive()

        XCTAssertEqual(String(decoding: message, as: UTF8.self), "fresh")
        await transport.close()
    }

    func testCancellingWaitingReceiveDoesNotConsumeNextSocketData() async throws {
        let server = try await LocalGatewayWebSocketServer(mode: "cancel")
        defer { server.stop() }
        let transport = URLSessionGatewayTransport(url: server.url)
        try await transport.open()
        let waitingReceive = Task { try await transport.receive() }
        try await Task.sleep(for: .milliseconds(100))
        waitingReceive.cancel()

        do {
            _ = try await waitingReceive.value
            XCTFail("cancelled receive should not return a socket message")
        } catch is CancellationError {
            // Expected: the next receive remains available for the live socket.
        }

        let next = try await transport.receive()
        let following = try await transport.receive()
        XCTAssertEqual(String(decoding: next, as: UTF8.self), "old")
        XCTAssertEqual(String(decoding: following, as: UTF8.self), "fresh")
        await transport.close()
    }
}

private final class LocalGatewayWebSocketServer: @unchecked Sendable {
    private let process = Process()
    private let portFile: URL
    let url: URL

    init(mode: String) async throws {
        self.portFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("operatorcore-websocket-\(UUID().uuidString)")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("gateway_ping_server.fixture")
        self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.process.arguments = ["python3", script.path, "--mode", mode, "--port-file", self.portFile.path]
        self.process.standardOutput = FileHandle.nullDevice
        self.process.standardError = FileHandle.nullDevice
        try self.process.run()

        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: self.portFile.path) {
            guard ContinuousClock.now < deadline else {
                self.process.terminate()
                try? FileManager.default.removeItem(at: self.portFile)
                throw LocalServerError.didNotStart
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let port = try Int(String(contentsOf: self.portFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)).unwrap(or: LocalServerError.invalidPort)
        self.url = URL(string: "ws://127.0.0.1:\(port)/")!
    }

    var pongCount: Int {
        get async { (try? Int(String(contentsOf: self.resultFile, encoding: .utf8)
            .split(separator: " ").first ?? "0")) ?? 0 }
    }

    func waitForText() async throws -> String {
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: self.resultFile.path) {
            guard ContinuousClock.now < deadline else { throw LocalServerError.noText }
            try await Task.sleep(for: .milliseconds(25))
        }
        let fields = try String(contentsOf: self.resultFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
        guard fields.count == 2 else { throw LocalServerError.noText }
        return String(fields[1])
    }

    func waitForHandshake() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: self.readyFile.path) {
            guard ContinuousClock.now < deadline else { throw LocalServerError.didNotStart }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func stop() {
        if self.process.isRunning { self.process.terminate() }
        try? FileManager.default.removeItem(at: self.portFile)
        try? FileManager.default.removeItem(at: self.resultFile)
        try? FileManager.default.removeItem(at: self.readyFile)
    }

    private var resultFile: URL { self.portFile.appendingPathExtension("result") }
    private var readyFile: URL { self.portFile.appendingPathExtension("ready") }
}

private enum LocalServerError: Error { case didNotStart, invalidPort, noText }

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
#endif
