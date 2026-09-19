import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

final class NativeNodePolicySetupTests: XCTestCase {
    func testWriteRequiresFreshAppliedReadbackBeforeReady() async throws {
        let before = PolicyTransport(allowed: false)
        let after = PolicyTransport(allowed: true)
        let factory = PolicyFactory([before, after])
        let setup = NativeNodePolicySetup(connectionFactory: { await factory.next() })
        let first = try await setup.prepare()
        let second = try await setup.prepare()
        XCTAssertFalse(first, "A successful write alone must not enable the node")
        XCTAssertTrue(second)
        let firstMethods = await before.methods
        let secondMethods = await after.methods
        let firstClosed = await before.closed
        let secondClosed = await after.closed
        XCTAssertEqual(firstMethods, ["connect", "config.get", "config.patch"])
        XCTAssertEqual(secondMethods, ["connect", "config.get"])
        XCTAssertTrue(firstClosed)
        XCTAssertTrue(secondClosed)
    }

    func testUncertainWriteIsNotRepeatedWhenNextReadStillShowsMissing() async throws {
        let before = PolicyTransport(allowed: false, failPatch: true)
        let after = PolicyTransport(allowed: false)
        let factory = PolicyFactory([before, after])
        let setup = NativeNodePolicySetup(connectionFactory: { await factory.next() })
        do {
            _ = try await setup.prepare()
            XCTFail("Failed patch must not report readiness")
        } catch {}
        let second = try await setup.prepare()
        XCTAssertFalse(second)
        let methods = await after.methods
        let closed = await before.closed
        XCTAssertEqual(methods, ["connect", "config.get"], "Do not repeat an uncertain write")
        XCTAssertTrue(closed)
    }

    func testStoredButNotAppliedPolicyWaitsWithoutWriting() async throws {
        let transport = PolicyTransport(allowed: true, applied: false)
        let factory = PolicyFactory([transport])
        let setup = NativeNodePolicySetup(connectionFactory: { await factory.next() })
        let ready = try await setup.prepare()
        let methods = await transport.methods
        XCTAssertFalse(ready)
        XCTAssertEqual(methods, ["connect", "config.get"])
    }
}

private actor PolicyFactory {
    private var transports: [PolicyTransport]
    init(_ transports: [PolicyTransport]) { self.transports = transports }
    func next() -> OpenClawGatewayConnection {
        OpenClawGatewayConnection(transport: transports.removeFirst(), token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
    }
}

private actor PolicyTransport: GatewayTransport {
    private let allowed: Bool
    private let applied: Bool
    private let failPatch: Bool
    private var frames: [Data] = []
    private(set) var methods: [String] = []
    private(set) var closed = false
    init(allowed: Bool, applied: Bool = true, failPatch: Bool = false) {
        self.allowed = allowed
        self.applied = applied
        self.failPatch = failPatch
    }
    func open() {
        frames.append(Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"test","ts":1}}"#.utf8))
    }
    func send(_ data: Data) throws {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try XCTUnwrap(request["method"] as? String)
        methods.append(method)
        var payload: [String: Any] = [:]
        if method == "config.get" {
            let commands: [String: Any] = allowed
                ? ["allow": GatewayNativeNodeSurface.commandPolicyAllow]
                : [:]
            payload = ["valid": true, "exists": true, "hash": "base", "configRevisionHash": "current",
                "appliedConfigHash": applied ? "current" : "old",
                "config": ["gateway": ["nodes": ["commands": commands]]]]
        } else if method == "config.patch" {
            if failPatch { throw URLError(.networkConnectionLost) }
            payload = ["ok": true]
        } else if method != "connect" {
            throw URLError(.unsupportedURL)
        }
        frames.append(try JSONSerialization.data(withJSONObject: ["type": "res", "id": request["id"]!, "ok": true, "payload": payload]))
    }
    func receive() throws -> Data {
        guard !frames.isEmpty else { throw URLError(.networkConnectionLost) }
        return frames.removeFirst()
    }
    func close() { closed = true }
}
