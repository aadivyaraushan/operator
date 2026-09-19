import Foundation
import XCTest
@testable import OperatorCore

final class GatewayNodePairingTests: XCTestCase {
    func testApprovesOnlyOwnDeviceNodeRoleWithMatchingKeyAndNoScopes() async throws {
        let pending = #"{"requestId":"pending-own","deviceId":"device-own","publicKey":"key-own","clientId":"node-host","clientMode":"node","deviceFamily":"iPhone","role":"node","roles":["node"],"scopes":[]}"#
        let approved = #"{"requestId":"pending-own","device":{"deviceId":"device-own","publicKey":"key-own","roles":["operator","node"]}}"#
        let fixture = try await PairingFixture.make(listPayload: "{\"pending\":[\(pending)],\"paired\":[]}", approvePayload: approved)
        try await fixture.connection.approveOwnNativeDeviceRole()
        let methods = try await fixture.methods()
        XCTAssertEqual(methods, ["connect", "device.pair.list", "device.pair.approve"])
    }

    func testRejectsWrongKeyRoleOrScopeBeforeDeviceApproval() async throws {
        let base = #"{"requestId":"pending-own","deviceId":"device-own","publicKey":"key-own","clientId":"node-host","clientMode":"node","deviceFamily":"iPhone","role":"node","roles":["node"],"scopes":[]}"#
        for changed in [base.replacingOccurrences(of: "key-own", with: "wrong-key"), base.replacingOccurrences(of: "\"roles\":[\"node\"]", with: "\"roles\":[\"operator\"]"), base.replacingOccurrences(of: "\"scopes\":[]", with: "\"scopes\":[\"operator.admin\"]")] {
            let fixture = try await PairingFixture.make(listPayload: "{\"pending\":[\(changed)],\"paired\":[]}")
            do { try await fixture.connection.approveOwnNativeDeviceRole(); XCTFail("Unexpected approval") }
            catch { XCTAssertEqual(error as? OpenClawGatewayError, .invalidFrame) }
            let methods = try await fixture.methods()
            XCTAssertEqual(methods, ["connect", "device.pair.list"])
        }
    }
    func testApprovesOnlyMatchingOwnPendingNativeSurface() async throws {
        let fixture = try await PairingFixture.make(listPayload: """
        {"pending":[\(OwnSurface.pending(requestId: "pending-own"))],"paired":[]}
        """, approvePayload: """
        \(OwnSurface.approval(requestId: "pending-own"))
        """)

        let approved = try await fixture.connection.prepareNativeNode()
        XCTAssertTrue(approved)
        let methods = try await fixture.methods()
        let approvalRequestID = try await fixture.approvalRequestID()
        XCTAssertEqual(methods, ["connect", "node.pair.list", "node.pair.approve"])
        XCTAssertEqual(approvalRequestID, "pending-own")
    }

    func testAlreadyApprovedExactSurfaceDoesNotWrite() async throws {
        let fixture = try await PairingFixture.make(listPayload: """
        {"pending":[],"paired":[{"nodeId":"device-own","caps":\(OwnSurface.capsJSON),"commands":\(OwnSurface.commandsJSON),"permissions":{}}]}
        """)

        let approved = try await fixture.connection.prepareNativeNode()
        XCTAssertFalse(approved)
        let methods = try await fixture.methods()
        XCTAssertEqual(methods, ["connect", "node.pair.list"])
    }

    func testForeignPendingIsIgnoredWhenOwnApprovedSurfaceMatches() async throws {
        let fixture = try await PairingFixture.make(listPayload: """
        {"pending":[\(OwnSurface.pending(requestId: "foreign", nodeId: "device-foreign"))],"paired":[\(OwnSurface.paired())]}
        """)

        let approved = try await fixture.connection.prepareNativeNode()
        XCTAssertFalse(approved)
        let methods = try await fixture.methods()
        XCTAssertEqual(methods, ["connect", "node.pair.list"])
    }

    func testAmbiguousOwnPendingFailsClosedWithoutApproval() async throws {
        let fixture = try await PairingFixture.make(listPayload: """
        {"pending":[
          {"requestId":"one","nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp","accounts","notion"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync","whatsapp.compose","connections.read","notion.tools","notion.call"]},
          {"requestId":"two","nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp","accounts","notion"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync","whatsapp.compose","connections.read","notion.tools","notion.call"]}
        ],"paired":[]}
        """)

        await XCTAssertThrowsInvalidFrame { try await fixture.connection.prepareNativeNode() }
        let methods = try await fixture.methods()
        XCTAssertEqual(methods, ["connect", "node.pair.list"])
    }

    func testMismatchedSurfaceAndPermissionsFailClosed() async throws {
        let payloads = [
            #"{"pending":[{"requestId":"own","nodeId":"device-own","caps":["location","calendar","sms","camera"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync"]}],"paired":[]}"#,
            #"{"pending":[{"requestId":"own","nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp"],"commands":["location.get","calendar.events"]}],"paired":[]}"#,
            #"{"pending":[{"requestId":"own","nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync"],"permissions":{"camera":true}}],"paired":[]}"#,
            #"{"pending":[{"requestId":" ","nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync"]}],"paired":[]}"#,
        ]
        for payload in payloads {
            let fixture = try await PairingFixture.make(listPayload: payload)
            await XCTAssertThrowsInvalidFrame { try await fixture.connection.prepareNativeNode() }
            let methods = try await fixture.methods()
            XCTAssertEqual(methods, ["connect", "node.pair.list"])
        }
    }

    func testAbsentOwnSurfaceFailsClosed() async throws {
        let fixture = try await PairingFixture.make(listPayload: #"{"pending":[],"paired":[]}"#)
        await XCTAssertThrowsInvalidFrame { try await fixture.connection.prepareNativeNode() }
    }

    func testIncorrectApprovalResponseFailsClosed() async throws {
        for response in [
            #"{"requestId":"stale","node":{"nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync"]}}"#,
            #"{"requestId":"pending-own","node":{"nodeId":"other","caps":["location","calendar","sms","maps","apps","whatsapp"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync"]}}"#,
            #"{"requestId":"pending-own","node":{"nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync"],"permissions":{"extra":true}}}"#,
        ] {
            let fixture = try await PairingFixture.make(listPayload: #"{"pending":[{"requestId":"pending-own","nodeId":"device-own","caps":["location","calendar","sms","maps","apps","whatsapp","accounts","notion"],"commands":["location.get","calendar.events","sms.compose","maps.search","maps.directions","apps.open","whatsapp.chats","whatsapp.messages","whatsapp.sync","whatsapp.compose","connections.read","notion.tools","notion.call"]}],"paired":[]}"#, approvePayload: response)
            await XCTAssertThrowsInvalidFrame { try await fixture.connection.prepareNativeNode() }
        }
    }

    func testServerApprovalRejectionPropagates() async throws {
        let fixture = try await PairingFixture.make(
            listPayload: #"{"pending":[\#(OwnSurface.pending(requestId: "pending-own"))],"paired":[]}"#,
            approveError: #"{"code":"INVALID_REQUEST","message":"unknown requestId"}"#)
        do {
            _ = try await fixture.connection.prepareNativeNode()
            XCTFail("approval rejection should throw")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error, .rejected(code: "INVALID_REQUEST", message: "unknown requestId"))
        }
    }
}

/// The current surface as a pending or paired node reports it. Fixtures that
/// mean "this matches" build from here rather than transcribing it; four of
/// them were transcribed and all four broke the moment the surface grew.
/// Fixtures that mean "this does not match" keep their own wrong values,
/// because there the exact wrongness is the point.
private enum OwnSurface {
    static var capsJSON: String {
        "[" + GatewayNativeNodeSurface.capabilities.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    static var commandsJSON: String {
        "[" + GatewayNativeNodeSurface.commands.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    static func pending(requestId: String, nodeId: String = "device-own") -> String {
        #"{"requestId":"\#(requestId)","nodeId":"\#(nodeId)","caps":\#(capsJSON),"commands":\#(commandsJSON)}"#
    }

    static func paired(nodeId: String = "device-own") -> String {
        #"{"nodeId":"\#(nodeId)","caps":\#(capsJSON),"commands":\#(commandsJSON)}"#
    }

    static func approval(requestId: String, nodeId: String = "device-own") -> String {
        #"{"requestId":"\#(requestId)","node":\#(paired(nodeId: nodeId))}"#
    }
}

private struct PairingFixture {
    let connection: OpenClawGatewayConnection
    let transport: PairingRecordingTransport

    static func make(
        listPayload: String,
        approvePayload: String? = nil,
        approveError: String? = nil) async throws -> PairingFixture
    {
        let identity = GatewayDeviceIdentity()
        let key = identity.publicKey.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let listPayload = listPayload.replacingOccurrences(
            of: "device-own", with: identity.deviceID).replacingOccurrences(of: "key-own", with: key)
        let approvePayload = approvePayload?.replacingOccurrences(
            of: "device-own", with: identity.deviceID).replacingOccurrences(of: "key-own", with: key)
        var incoming = [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#,
            "{\"type\":\"res\",\"id\":\"list-1\",\"ok\":true,\"payload\":\(listPayload)}",
        ]
        if let approvePayload {
            incoming.append("{\"type\":\"res\",\"id\":\"approve-1\",\"ok\":true,\"payload\":\(approvePayload)}")
        } else if let approveError {
            incoming.append("{\"type\":\"res\",\"id\":\"approve-1\",\"ok\":false,\"error\":\(approveError)}")
        }
        let transport = PairingRecordingTransport(incoming: incoming)
        let connection = OpenClawGatewayConnection(
            transport: transport, token: "token", identity: identity,
            metadata: .init(appVersion: "1.0", platform: "ios", instanceID: "install"),
            requestID: PairingRequestIDSequence(["connect-1", "list-1", "approve-1"]).next)
        try await connection.connect()
        return PairingFixture(connection: connection, transport: transport)
    }

    func methods() async throws -> [String] {
        try await self.transport.sentMessages().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["method"] as? String ?? ""
        }
    }

    func approvalRequestID() async throws -> String? {
        let sent = await self.transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[2]) as? [String: Any])
        return (request["params"] as? [String: Any])?["requestId"] as? String
    }
}

private func XCTAssertThrowsInvalidFrame(
    _ operation: () async throws -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line) async
{
    do {
        _ = try await operation()
        XCTFail("expected invalidFrame", file: file, line: line)
    } catch let error as OpenClawGatewayError {
        XCTAssertEqual(error, .invalidFrame, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private actor PairingRecordingTransport: GatewayTransport {
    private var incoming: [Data]
    private var sent: [Data] = []
    init(incoming: [String]) { self.incoming = incoming.map { Data($0.utf8) } }
    func open() async throws {}
    func send(_ data: Data) async throws { self.sent.append(data) }
    func receive() async throws -> Data {
        guard !self.incoming.isEmpty else { throw PairingTestError.noMessage }
        return self.incoming.removeFirst()
    }
    func close() async {}
    func sentMessages() -> [Data] { self.sent }
}

private enum PairingTestError: Error { case noMessage }

private final class PairingRequestIDSequence: @unchecked Sendable {
    private var values: [String]
    private let lock = NSLock()
    init(_ values: [String]) { self.values = values }
    func next() -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.removeFirst()
    }
}
