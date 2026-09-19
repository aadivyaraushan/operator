import Foundation
import Network
import XCTest
@testable import OperatorApp

final class NotionLoopbackCallbackTests: XCTestCase {
    func testAcceptsOneExactLocalCallbackAndThenCloses() async throws {
        let server = NotionLoopbackCallbackServer(timeoutSeconds: 2)
        let redirect = try await server.start(port: nil)
        let callback = Task { try await server.receive(expectedState: "state-value") }
        var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "code", value: "code-value"), .init(name: "state", value: "state-value")]
        let (_, response) = try await URLSession.shared.data(from: parts.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let received = try await callback.value
        XCTAssertEqual(received, parts.url)
        await XCTAssertThrowsErrorAsync(try await server.receive(expectedState: "state-value"))
    }

    func testAcceptsOAuthSuccessCallbackWithUnknownResponseFields() async throws {
        let server = NotionLoopbackCallbackServer(timeoutSeconds: 2)
        let redirect = try await server.start(port: nil)
        let receive = Task { try await server.receive(expectedState: "state-value") }
        var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "code", value: "code-value"),
            .init(name: "state", value: "state-value"),
            .init(name: "scope", value: "read write"),
            .init(name: "provider_hint", value: "ignored"),
        ]

        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(parts.url))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let received = try await receive.value
        XCTAssertEqual(received, parts.url)
    }

    func testAcceptsOAuthDenialCallbackWithOptionalDescription() async throws {
        let server = NotionLoopbackCallbackServer(timeoutSeconds: 2)
        let redirect = try await server.start(port: nil)
        let receive = Task { try await server.receive(expectedState: "state-value") }
        var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "error", value: "access_denied"),
            .init(name: "state", value: "state-value"),
            .init(name: "error_description", value: "The user denied access"),
        ]

        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(parts.url))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let received = try await receive.value
        XCTAssertEqual(received, parts.url)
    }

    func testRejectsWrongPathHostAndDuplicateProtectedFields() async throws {
        for suffix in [
            "/wrong?code=c&state=s",
            "/notion/callback?code=c&code=d&state=s",
            "/notion/callback?code=c&state=s&state=t",
            "/notion/callback?error=access_denied&error=server_error&state=s",
        ] {
            let server = NotionLoopbackCallbackServer(timeoutSeconds: 1)
            let redirect = try await server.start(port: nil)
            let receive = Task { try await server.receive(expectedState: "s") }
            let url = URL(string: "http://127.0.0.1:\(redirect.port!)\(suffix)")!
            let (_, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
            await server.cancel()
            await XCTAssertThrowsErrorAsync(try await receive.value)
        }
    }

    func testCancelAndTimeoutCloseListener() async throws {
        let cancelled = NotionLoopbackCallbackServer(timeoutSeconds: 2)
        _ = try await cancelled.start(port: nil)
        let receive = Task { try await cancelled.receive(expectedState: "s") }
        await cancelled.cancel()
        await XCTAssertThrowsErrorAsync(try await receive.value) { XCTAssertTrue($0 is CancellationError) }

        let timed = NotionLoopbackCallbackServer(timeoutSeconds: 0.02)
        _ = try await timed.start(port: nil)
        await XCTAssertThrowsErrorAsync(try await timed.receive(expectedState: "s")) {
            XCTAssertEqual($0 as? NotionLoopbackCallbackError, .timedOut)
        }
    }

    func testSlowIncompleteHTTPRequestUsesShortReadDeadline() async throws {
        let server = NotionLoopbackCallbackServer(timeoutSeconds: 2, requestTimeoutSeconds: 0.02)
        let redirect = try await server.start(port: nil)
        let receive = Task { try await server.receive(expectedState: "s") }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: UInt16(redirect.port!))!,
            using: .tcp)
        connection.start(queue: DispatchQueue(label: "notion-loopback-slow-test"))
        await XCTAssertThrowsErrorAsync(try await receive.value) {
            XCTAssertEqual($0 as? NotionLoopbackCallbackError, .invalidRequest)
        }
        connection.cancel()
    }

    func testAcceptsHeaderSplitAcrossTCPReads() async throws {
        let server = NotionLoopbackCallbackServer(timeoutSeconds: 2, requestTimeoutSeconds: 1)
        let redirect = try await server.start(port: nil)
        let receive = Task { try await server.receive(expectedState: "split-state") }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: UInt16(redirect.port!))!,
            using: .tcp)
        connection.start(queue: DispatchQueue(label: "notion-loopback-split-test"))
        let first = "GET /notion/callback?code=split-code&state=split-state HTTP/1.1\r\nHo"
        let second = "st: 127.0.0.1:\(redirect.port!)\r\n\r\n"
        try await send(Data(first.utf8), over: connection)
        try await Task.sleep(for: .milliseconds(10))
        try await send(Data(second.utf8), over: connection)
        let callback = try await receive.value
        XCTAssertEqual(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.count, 2)
        connection.cancel()
    }
}

private func send(_ data: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        })
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ check: (Error) -> Void = { _ in }
) async {
    do { _ = try await expression(); XCTFail("Expected error") } catch { check(error) }
}
