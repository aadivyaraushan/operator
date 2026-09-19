import Foundation
import XCTest
@testable import OperatorCore

final class WhatsAppLinkGatewayClientTests: XCTestCase {
    func testStartUsesFreshConnectionAndSendsOnlyPhone() async throws {
        let fixture = try await WhatsAppLinkFixture.make(payload: #"{"operationId":"op-1","phase":"waiting_for_code"}"#)
        let client = WhatsAppLinkGatewayClient(connectionFactory: fixture.factory)

        let operation = try await client.start(phone: "+15551234567")

        XCTAssertEqual(operation.operationID, "op-1")
        XCTAssertEqual(operation.phase, .waitingForCode)
        let calls = await fixture.factoryCallCount()
        let methods = try await fixture.methods()
        let params = try await fixture.params(at: 1)
        let closes = await fixture.transportCloseCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(methods, ["connect", "operator.whatsappLink.start"])
        XCTAssertEqual(params, ["phone": "+15551234567"])
        XCTAssertEqual(closes, 1)
    }

    func testStatusSendsOnlyOperationIDAndReturnsOptionalCode() async throws {
        let fixture = try await WhatsAppLinkFixture.make(payload: #"{"operationId":"op-1","phase":"code_ready","pairCode":"ABCD-1234"}"#)
        let client = WhatsAppLinkGatewayClient(connectionFactory: fixture.factory)

        let status = try await client.status(operationID: "op-1")

        XCTAssertEqual(status.operationID, "op-1")
        XCTAssertEqual(status.phase, .codeReady)
        XCTAssertEqual(status.pairCode, "ABCD-1234")
        let methods = try await fixture.methods()
        let params = try await fixture.params(at: 1)
        XCTAssertEqual(methods, ["connect", "operator.whatsappLink.status"])
        XCTAssertEqual(params, ["operationId": "op-1"])
    }

    func testCancelUsesFreshConnectionAndSendsOnlyOperationID() async throws {
        let fixture = try await WhatsAppLinkFixture.make(payload: #"{"operationId":"op-1","phase":"cancelled"}"#)
        let client = WhatsAppLinkGatewayClient(connectionFactory: fixture.factory)

        let operation = try await client.cancel(operationID: "op-1")

        XCTAssertEqual(operation.operationID, "op-1")
        XCTAssertEqual(operation.phase, .cancelled)
        let calls = await fixture.factoryCallCount()
        let methods = try await fixture.methods()
        let params = try await fixture.params(at: 1)
        let closes = await fixture.transportCloseCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(methods, ["connect", "operator.whatsappLink.cancel"])
        XCTAssertEqual(params, ["operationId": "op-1"])
        XCTAssertEqual(closes, 1)
    }

    func testStatusDecodesEverySupportedPhase() async throws {
        let cases: [(String, WhatsAppLinkPhase)] = [
            ("waiting_for_code", .waitingForCode),
            ("code_ready", .codeReady),
            ("finishing", .finishing),
            ("cancelled", .cancelled),
            ("failed", .failed),
            ("linked", .linked),
        ]

        for (wirePhase, expected) in cases {
            let fixture = try await WhatsAppLinkFixture.make(payload: #"{"operationId":"op-1","phase":"\#(wirePhase)"}"#)
            let client = WhatsAppLinkGatewayClient(connectionFactory: fixture.factory)
            let status = try await client.status(operationID: "op-1")
            XCTAssertEqual(status.phase, expected)
        }
    }

    func testMalformedResponsesFailClosed() async throws {
        let payloads = [
            #"{"operationId":"","phase":"linked"}"#,
            #"{"operationId":"op-1","phase":"unknown"}"#,
            #"{"operationId":"op-1","phase":"waiting_for_code","pairCode":"ABCD-1234"}"#,
            #"{"operationId":"op-1"}"#,
        ]

        for payload in payloads {
            let fixture = try await WhatsAppLinkFixture.make(payload: payload)
            let client = WhatsAppLinkGatewayClient(connectionFactory: fixture.factory)
            await XCTAssertThrowsErrorAsync { _ = try await client.status(operationID: "op-1") }
            let closes = await fixture.transportCloseCount()
            XCTAssertEqual(closes, 1)
        }
    }

    func testStartAndCancelRejectResponsesThatContainPairCodes() async throws {
        for method in ["start", "cancel"] {
            let fixture = try await WhatsAppLinkFixture.make(payload: #"{"operationId":"op-1","phase":"code_ready","pairCode":"ABCD-1234"}"#)
            let client = WhatsAppLinkGatewayClient(connectionFactory: fixture.factory)
            if method == "start" {
                await XCTAssertThrowsErrorAsync { _ = try await client.start(phone: "+15551234567") }
            } else {
                await XCTAssertThrowsErrorAsync { _ = try await client.cancel(operationID: "op-1") }
            }
        }
    }
}

private struct WhatsAppLinkFixture {
    let factory: @Sendable () async throws -> OpenClawGatewayConnection
    let transport: WhatsAppLinkTransport
    private let factoryState: WhatsAppLinkFactory

    static func make(payload: String) async throws -> WhatsAppLinkFixture {
        let transport = WhatsAppLinkTransport(incoming: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect","ok":true,"payload":{"status":"connected"}}"#,
            "{\"type\":\"res\",\"id\":\"request\",\"ok\":true,\"payload\":\(payload)}",
        ])
        let ids = WhatsAppLinkIDs(["connect", "request"])
        let connection = OpenClawGatewayConnection(
            transport: transport, token: "token", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1", platform: "ios", instanceID: "install"), requestID: ids.next)
        let factoryState = WhatsAppLinkFactory(connection: connection)
        return WhatsAppLinkFixture(factory: { try await factoryState.make() }, transport: transport, factoryState: factoryState)
    }

    func factoryCallCount() async -> Int { await factoryState.callCount() }
    func transportCloseCount() async -> Int { await transport.closeCount() }

    func methods() async throws -> [String] {
        try await transport.sentMessages().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) ["method"] as? String ?? ""
        }
    }

    func params(at index: Int) async throws -> [String: String] {
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[index]) as? [String: Any])
        return try XCTUnwrap(request["params"] as? [String: String])
    }
}

private actor WhatsAppLinkFactory {
    private let connection: OpenClawGatewayConnection
    private var calls = 0

    init(connection: OpenClawGatewayConnection) { self.connection = connection }

    func make() throws -> OpenClawGatewayConnection {
        calls += 1
        guard calls == 1 else { throw WhatsAppLinkTestError.factoryUsedMoreThanOnce }
        return connection
    }

    func callCount() -> Int { calls }
}

private actor WhatsAppLinkTransport: GatewayTransport {
    private var incoming: [Data]
    private var sent: [Data] = []
    private var closes = 0

    init(incoming: [String]) { self.incoming = incoming.map { Data($0.utf8) } }
    func open() async throws {}
    func send(_ data: Data) async throws { sent.append(data) }
    func receive() async throws -> Data {
        guard !incoming.isEmpty else { throw WhatsAppLinkTestError.empty }
        return incoming.removeFirst()
    }
    func close() async { closes += 1 }
    func sentMessages() -> [Data] { sent }
    func closeCount() -> Int { closes }
}

private final class WhatsAppLinkIDs: @unchecked Sendable {
    private var values: [String]
    private let lock = NSLock()
    init(_ values: [String]) { self.values = values }
    func next() -> String { lock.lock(); defer { lock.unlock() }; return values.removeFirst() }
}

private enum WhatsAppLinkTestError: Error { case empty, factoryUsedMoreThanOnce }

private func XCTAssertThrowsErrorAsync(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("expected error", file: file, line: line) } catch {}
}
