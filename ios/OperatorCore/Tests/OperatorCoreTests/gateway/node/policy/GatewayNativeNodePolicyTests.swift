
/// The allow policy Operator installs, derived rather than transcribed. It is
/// existing entries followed by every required command not already among them,
/// in commandPolicyAllow order - so adding a command to the surface cannot
/// silently invalidate these fixtures the way it did once already.
private enum AllowPolicy {
    static func json(_ existing: [String]) -> String {
        let merged = existing + GatewayNativeNodeSurface.commandPolicyAllow.filter { !existing.contains($0) }
        return "[" + merged.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}

import Foundation
import XCTest
@testable import OperatorCore

final class GatewayNativeNodePolicyTests: XCTestCase {
    func testReadsReadyWaitingAndMissingStatesWithoutWriting() async throws {
        let cases: [(String, GatewayNativeNodePolicyState)] = [
            (#"{"valid":true,"hash":"raw-1","configRevisionHash":"rev-1","appliedConfigHash":"rev-1","config":{"gateway":{"nodes":{"commands":{"allow":\#(AllowPolicy.json(["other"]))}}}}}"#, .ready),
            (#"{"valid":true,"hash":"raw-1","configRevisionHash":"rev-2","appliedConfigHash":"rev-1","config":{"gateway":{"nodes":{"commands":{"allow":["sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync","whatsapp.compose","connections.read","connections.write","connections.describe","notion.tools","notion.call"]}}}}}"#, .waitingForApply),
            (#"{"valid":true,"hash":"raw-1","configRevisionHash":"rev-2","appliedConfigHash":"rev-1","config":{}}"#, .waitingForApply),
            (#"{"valid":true,"hash":"raw-1","configRevisionHash":"rev-2","appliedConfigHash":null,"config":{}}"#, .waitingForApply),
            (#"{"valid":true,"hash":"raw-1","configRevisionHash":"rev-1","appliedConfigHash":"rev-1","config":{}}"#, .missing(baseHash: "raw-1", existingAllow: [])),
            (#"{"valid":true,"hash":"raw-1","configRevisionHash":"rev-1","appliedConfigHash":"rev-1","config":{"gateway":{"nodes":{"commands":{"allow":["other","sms.compose"]}}}}}"#, .missing(baseHash: "raw-1", existingAllow: ["other", "sms.compose"])),
        ]
        for (payload, expected) in cases {
            let fixture = try await PolicyFixture.make(payloads: [payload])
            let state = try await fixture.connection.nativeNodePolicyState()
            let methods = try await fixture.methods()
            XCTAssertEqual(state, expected)
            XCTAssertEqual(methods, ["connect", "config.get"])
        }
    }

    func testExplicitConflictsAndMalformedConfigFailClosed() async throws {
        let payloads = [
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":{"nodes":{"commands":{"deny":["sms.compose"]}}}}}"#,
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":{"nodes":{"commands":{"deny":[" maps.search "]}}}}}"#,
            #"{"valid":false,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{}}"#,
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":"bad"}}"#,
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":null}}"#,
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":{"nodes":{"commands":null}}}}"#,
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":{"nodes":{"commands":{"allow":null}}}}}"#,
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":{"nodes":{"commands":{"deny":null}}}}}"#,
            #"{"valid":true,"hash":"raw","configRevisionHash":"rev","appliedConfigHash":"rev","config":{"gateway":{"nodes":{"commands":{"allow":[1]}}}}}"#,
            #"{"valid":true,"hash":"","configRevisionHash":"rev","appliedConfigHash":"rev","config":{}}"#,
        ]
        for payload in payloads {
            let fixture = try await PolicyFixture.make(payloads: [payload])
            await XCTAssertThrowsErrorAsync { _ = try await fixture.connection.nativeNodePolicyState() }
            let methods = try await fixture.methods()
            XCTAssertEqual(methods, ["connect", "config.get"])
        }
    }

    func testPolicyRequiresEveryAdvertisedCommandMissingFromRuntimeDefaults() async throws {
        let runtimeDefaultAllow = [
            "weather.forecast", "device.status", "sms.compose", "maps.search", "maps.directions",
            "apps.open", "whatsapp.chats", "whatsapp.messages", "whatsapp.sync", "whatsapp.compose",
            "connections.read", "connections.write", "connections.describe", "notion.tools", "notion.call",
            "youtube.search", "youtube.open", "podcasts.search", "podcasts.open",
        ]
        let payload = try JSONSerialization.data(withJSONObject: [
            "valid": true,
            "hash": "raw-1",
            "configRevisionHash": "rev-1",
            "appliedConfigHash": "rev-1",
            "config": ["gateway": ["nodes": ["commands": ["allow": runtimeDefaultAllow]]]],
        ])
        let fixture = try await PolicyFixture.make(payloads: [String(decoding: payload, as: UTF8.self)])

        let state = try await fixture.connection.nativeNodePolicyState()

        XCTAssertEqual(state, .missing(baseHash: "raw-1", existingAllow: runtimeDefaultAllow))
    }

    func testInstallsMissingCommandsWithExactBaseHashWithoutDroppingOtherAllows() async throws {
        let fixture = try await PolicyFixture.make(payloads: [#"{"ok":true,"hash":"new"}"#])
        try await fixture.connection.installNativeNodeAllowPolicy(baseHash: "raw-1", existingAllow: ["other", "sms.compose"])
        let sent = await fixture.transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "config.patch")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["baseHash"] as? String, "raw-1")
        XCTAssertEqual(params["raw"] as? String, #"{"gateway":{"nodes":{"commands":{"allow":\#(AllowPolicy.json(["other", "sms.compose"]))}}}}"#)
    }

    func testPatchRejectsEmptyHashAndInvalidOrRejectedResponse() async throws {
        let empty = try await PolicyFixture.make(payloads: [])
        await XCTAssertThrowsErrorAsync { try await empty.connection.installNativeNodeAllowPolicy(baseHash: " ", existingAllow: []) }
        let methods = try await empty.methods()
        XCTAssertEqual(methods, ["connect"])

        let invalid = try await PolicyFixture.make(payloads: [#"{"ok":false}"#])
        await XCTAssertThrowsErrorAsync { try await invalid.connection.installNativeNodeAllowPolicy(baseHash: "raw", existingAllow: []) }

        let rejected = try await PolicyFixture.make(payloads: [], error: #"{"code":"INVALID_REQUEST","message":"config changed"}"#)
        await XCTAssertThrowsErrorAsync { try await rejected.connection.installNativeNodeAllowPolicy(baseHash: "raw", existingAllow: []) }
    }
}

private struct PolicyFixture {
    let connection: OpenClawGatewayConnection
    let transport: PolicyTransport

    static func make(payloads: [String], error: String? = nil) async throws -> PolicyFixture {
        var incoming = [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect","ok":true,"payload":{"status":"connected"}}"#,
        ]
        for (index, payload) in payloads.enumerated() {
            incoming.append("{\"type\":\"res\",\"id\":\"request-\(index)\",\"ok\":true,\"payload\":\(payload)}")
        }
        if let error { incoming.append("{\"type\":\"res\",\"id\":\"request-0\",\"ok\":false,\"error\":\(error)}") }
        let transport = PolicyTransport(incoming: incoming)
        let ids = PolicyIDs(["connect", "request-0", "request-1"])
        let connection = OpenClawGatewayConnection(
            transport: transport, token: "token", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1", platform: "ios", instanceID: "install"), requestID: ids.next)
        try await connection.connect()
        return PolicyFixture(connection: connection, transport: transport)
    }

    func methods() async throws -> [String] {
        try await transport.sentMessages().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["method"] as? String ?? ""
        }
    }
}

private actor PolicyTransport: GatewayTransport {
    private var incoming: [Data]
    private var sent: [Data] = []
    init(incoming: [String]) { self.incoming = incoming.map { Data($0.utf8) } }
    func open() async throws {}
    func send(_ data: Data) async throws { sent.append(data) }
    func receive() async throws -> Data { guard !incoming.isEmpty else { throw PolicyTestError.empty }; return incoming.removeFirst() }
    func close() async {}
    func sentMessages() -> [Data] { sent }
}

private final class PolicyIDs: @unchecked Sendable {
    private var values: [String]; private let lock = NSLock()
    init(_ values: [String]) { self.values = values }
    func next() -> String { lock.lock(); defer { lock.unlock() }; return values.removeFirst() }
}

private enum PolicyTestError: Error { case empty }

private func XCTAssertThrowsErrorAsync(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("expected error", file: file, line: line) } catch {}
}
