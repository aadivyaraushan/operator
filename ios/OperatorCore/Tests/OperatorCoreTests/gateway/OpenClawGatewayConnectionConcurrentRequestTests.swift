import Foundation
import XCTest
@testable import OperatorCore

final class OpenClawGatewayConnectionConcurrentRequestTests: XCTestCase {
    func testConcurrentTypedRequestsAreSerializedAndKeepTheirOwnDifferentResultTypes() async throws {
        let transport = CrossedResponseTransport()
        let connection = try await self.connected(transport: transport)
        let first = Task { try await connection.request(method: "first", params: ConcurrentRequestParams()) as ConcurrentFirstResult }
        try await self.waitForWaiters(in: transport, count: 1)
        let second = Task { try await connection.request(method: "second", params: ConcurrentRequestParams()) as ConcurrentSecondResult }
        try await Task.sleep(for: .milliseconds(20))
        let sentBeforeFirst = await transport.sentMethods()
        let waitersBeforeFirst = await transport.waiterCount
        XCTAssertEqual(sentBeforeFirst, ["first"])
        XCTAssertEqual(waitersBeforeFirst, 1)
        await transport.resumeNext(with: Self.response(id: "first-1", payload: #"{"label":"first"}"#))
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.label, "first")
        try await self.waitForWaiters(in: transport, count: 1)
        let sentBeforeSecond = await transport.sentMethods()
        XCTAssertEqual(sentBeforeSecond, ["first", "second"])
        await transport.resumeNext(with: Self.response(id: "second-1", payload: #"{"enabled":true}"#))
        let secondResult = try await second.value
        XCTAssertTrue(secondResult.enabled)
    }

    func testCancellingQueuedTypedRequestDoesNotSendIt() async throws {
        let transport = CrossedResponseTransport()
        let connection = try await self.connected(transport: transport)
        let first = Task { let _: ConcurrentFirstResult = try await connection.request(method: "first", params: ConcurrentRequestParams()) }
        try await self.waitForWaiters(in: transport, count: 1)
        let second = Task { () -> Bool in
            do { let _: ConcurrentSecondResult = try await connection.request(method: "second", params: ConcurrentRequestParams()); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        second.cancel()
        try await Task.sleep(for: .milliseconds(20))
        let sent = await transport.sentMethods()
        XCTAssertEqual(sent, ["first"])
        await connection.disconnect()
        let secondWasCancelled = await second.value
        XCTAssertTrue(secondWasCancelled)
        _ = try? await first.value
    }

    func testDisconnectReleasesActiveAndQueuedTypedRequests() async throws {
        let transport = CrossedResponseTransport()
        let connection = try await self.connected(transport: transport)
        let first = Task { () -> Bool in
            do { let _: ConcurrentFirstResult = try await connection.request(method: "first", params: ConcurrentRequestParams()); return false }
            catch { return true }
        }
        try await self.waitForWaiters(in: transport, count: 1)
        let second = Task { () -> Bool in
            do { let _: ConcurrentSecondResult = try await connection.request(method: "second", params: ConcurrentRequestParams()); return false }
            catch { return true }
        }
        try await Task.sleep(for: .milliseconds(20))
        let sent = await transport.sentMethods()
        XCTAssertEqual(sent, ["first"])
        await connection.disconnect()
        let firstFailed = await first.value
        let secondFailed = await second.value
        XCTAssertTrue(firstFailed)
        XCTAssertTrue(secondFailed)
    }

    func testTypedRequestBuffersUnrelatedInboundEventForReceive() async throws {
        let transport = CrossedResponseTransport()
        let connection = try await self.connected(transport: transport)
        let request = Task { try await connection.request(method: "first", params: ConcurrentRequestParams()) as ConcurrentFirstResult }
        try await self.waitForWaiters(in: transport, count: 1)
        await transport.resumeNext(with: Data(#"{"type":"event","event":"ignored"}"#.utf8))
        try await self.waitForWaiters(in: transport, count: 1)
        await transport.resumeNext(with: Self.response(id: "first-1", payload: #"{"label":"first"}"#))
        _ = try await request.value
        let inbound = try await connection.receive()
        XCTAssertEqual(inbound, .ignored(event: "ignored"))
    }

    private func connected(transport: CrossedResponseTransport) async throws -> OpenClawGatewayConnection {
        let ids = ConcurrentRequestIDSequence(["connect-1", "first-1", "second-1"])
        let connection = OpenClawGatewayConnection(transport: transport, token: "local-token", identity: GatewayDeviceIdentity(), metadata: .init(appVersion: "1.0", platform: "iOS", instanceID: "install-1"), requestID: ids.next)
        try await connection.connect()
        return connection
    }

    private func waitForWaiters(in transport: CrossedResponseTransport, count: Int) async throws {
        for _ in 0 ..< 100 {
            if await transport.waiterCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("expected \(count) waiting reads, found \(await transport.waiterCount)")
    }

    private static func response(id: String, payload: String) -> Data {
        Data("{\"type\":\"res\",\"id\":\"\(id)\",\"ok\":true,\"payload\":\(payload)}".utf8)
    }
}

private struct ConcurrentRequestParams: Encodable, Sendable {}
private struct ConcurrentFirstResult: Decodable, Sendable { let label: String }
private struct ConcurrentSecondResult: Decodable, Sendable { let enabled: Bool }

private actor CrossedResponseTransport: GatewayTransport {
    private var incoming = [
        Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#.utf8),
        Data(#"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#.utf8),
    ]
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var methods: [String] = []
    private var closed = false

    func open() async throws {}
    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let method = object?["method"] as? String, method != "connect" { self.methods.append(method) }
    }
    func receive() async throws -> Data {
        if !self.incoming.isEmpty { return self.incoming.removeFirst() }
        if self.closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { self.waiters.append($0) }
    }
    func close() async {
        self.closed = true
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }
    var waiterCount: Int { self.waiters.count }
    func sentMethods() -> [String] { self.methods }
    func resumeNext(with response: Data) { self.waiters.removeFirst().resume(returning: response) }
}

private final class ConcurrentRequestIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    init(_ values: [String]) { self.values = values }
    func next() -> String { self.lock.lock(); defer { self.lock.unlock() }; return self.values.removeFirst() }
}
