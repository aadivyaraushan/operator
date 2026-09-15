import Foundation
import XCTest
@testable import OperatorCore

final class OpenClawGatewayConnectionTests: XCTestCase {
    func testConnectCapturesTrimmedGatewayBootIDAndDisconnectClearsIt() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"server":{"bootId":"  boot-first \n"}}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, accepted])
        let connection = OpenClawGatewayConnection(
            transport: transport, token: "local-token", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS", instanceID: "install-1"),
            requestID: { "connect-1" })
        try await connection.connect()
        let bootID = await connection.currentGatewayBootID
        XCTAssertEqual(bootID, "boot-first")
        await connection.disconnect()
        let disconnectedBootID = await connection.currentGatewayBootID
        XCTAssertNil(disconnectedBootID)
    }

    func testConnectWithoutUsableBootIDPreservesCompatibility() async throws {
        for payload in [#"{}"#, #"{"server":{}}"#, #"{"server":{"bootId":" \n "}}"#] {
            let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
            let accepted = "{\"type\":\"res\",\"id\":\"connect-1\",\"ok\":true,\"payload\":\(payload)}"
            let connection = OpenClawGatewayConnection(
                transport: RecordingGatewayTransport(incoming: [challenge, accepted]),
                token: "local-token", identity: GatewayDeviceIdentity(),
                metadata: .init(appVersion: "1.0", platform: "iOS", instanceID: "install-1"),
                requestID: { "connect-1" })
            try await connection.connect()
            let bootID = await connection.currentGatewayBootID
            let connected = await connection.isConnected
            XCTAssertNil(bootID)
            XCTAssertTrue(connected)
        }
    }

    func testFailedReconnectDoesNotPublishBootIdentityFromRejectedResponse() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"server":{"bootId":"old-boot"}}}"#
        let rejected = #"{"type":"res","id":"connect-2","ok":false,"payload":{"server":{"bootId":"untrusted-boot"}},"error":{"code":"AUTH_FAILED","message":"rejected"}}"#
        let connection = OpenClawGatewayConnection(
            transport: RecordingGatewayTransport(incoming: [challenge, accepted, challenge, rejected]),
            token: "local-token", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS", instanceID: "install-1"),
            requestID: RequestIDSequence(["connect-1", "connect-2"]).next)
        try await connection.connect()
        await connection.disconnect()
        do {
            try await connection.connect()
            XCTFail("reconnect should fail")
        } catch {}
        let bootID = await connection.currentGatewayBootID
        XCTAssertNil(bootID)
    }

    func testConnectWaitsForChallengeAndSendsSignedProtocolFourRequest() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"request-1","ok":true,"payload":{"status":"connected"}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, accepted])
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(
                appVersion: "1.0",
                platform: "iOS 18.5.0",
                instanceID: "install-1"),
            requestID: RequestIDSequence(["request-1"]).next)

        try await connection.connect()

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sent[0]) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let device = try XCTUnwrap(params["device"] as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "connect")
        XCTAssertEqual(device["nonce"] as? String, "nonce-1")
        let connected = await connection.isConnected
        XCTAssertTrue(connected)
    }

    func testSendUsesStableKeyAndReceiveReducesCurrentChatEvent() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#
        let chat = #"{"type":"event","event":"chat","seq":1,"payload":{"runId":"run-1","sessionKey":"agent:main:main","seq":1,"state":"delta","deltaText":"Hello"}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, accepted, chat])
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS 18.5.0", instanceID: "install-1"),
            sessionKey: "agent:main:main",
            requestID: RequestIDSequence(["connect-1", "send-1"]).next)
        try await connection.connect()

        let requestID = try await connection.sendMessage(
            "hi",
            idempotencyKey: "message-1")
        let inbound = try await connection.receive()

        XCTAssertEqual(requestID, "send-1")
        XCTAssertEqual(
            inbound,
            .conversation([
                .working(runID: "run-1"),
                .stream(runID: "run-1", text: "Hello"),
            ]))
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["idempotencyKey"] as? String, "message-1")
    }

    func testOnlyToolAgentEventsReachTheAppAndLifecycleOnesStayIgnored() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#
        let valid = #"{"type":"event","event":"agent","payload":{"runId":"run-1","sessionKey":"agent:main:main","stream":"codex_app_server.lifecycle","data":{"phase":"thread_ready","threadId":"sensitive","model":"sensitive"},"seq":2,"ts":3}}"#
        let unknown = #"{"type":"event","event":"agent","payload":{"runId":"run-1","sessionKey":"agent:main:main","stream":"codex_app_server.lifecycle","data":{"phase":"future_phase"}}}"#
        let malformed = #"{"type":"event","event":"agent","payload":{"runId":7,"sessionKey":"agent:main:main","stream":"codex_app_server.lifecycle","data":{"phase":"startup"}}}"#
        let foreign = #"{"type":"event","event":"agent","payload":{"runId":"run-1","sessionKey":"agent:other:main","stream":"codex_app_server.lifecycle","data":{"phase":"startup"}}}"#
        let tool = #"{"type":"event","event":"agent","payload":{"runId":"run-1","sessionKey":"agent:main:main","stream":"tool","seq":5,"data":{"phase":"start","name":"discord_announcements","toolCallId":"call-9","args":{"limit":25}}}}"#
        let chat = #"{"type":"event","event":"chat","payload":{"runId":"run-1","sessionKey":"agent:main:main","seq":1,"state":"final","message":"Hello"}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, accepted, valid, unknown, malformed, foreign, tool, chat])
        let connection = OpenClawGatewayConnection(
            transport: transport, token: "local-token", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS", instanceID: "install-1"),
            sessionKey: "agent:main:main", requestID: { "connect-1" })
        try await connection.connect()

        let decoded = try await connection.receive()
        let ignoredUnknown = try await connection.receive()
        let ignoredMalformed = try await connection.receive()
        let ignoredForeign = try await connection.receive()
        let activity = try await connection.receive()
        let conversation = try await connection.receive()
        XCTAssertEqual(decoded, .ignored(event: "agent"))
        XCTAssertEqual(ignoredUnknown, .ignored(event: "agent"))
        XCTAssertEqual(ignoredMalformed, .ignored(event: "agent"))
        XCTAssertEqual(ignoredForeign, .ignored(event: "agent"))
        XCTAssertEqual(activity, .conversation([
            .working(runID: "run-1"),
            .activity(runID: "run-1", .toolStarted(tool: "discord_announcements", callID: "call-9", command: nil, operation: nil)),
        ]), "a tool start for this session is the one agent event that reaches the app")
        XCTAssertEqual(conversation, .conversation([.reply(runID: "run-1", text: "Hello")]), "working was already announced by the tool start")
        let sent = await transport.sentMessages()
        let connect = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[0]) as? [String: Any])
        XCTAssertEqual((connect["params"] as? [String: Any])?["caps"] as? [String], ["tool-events"], "without the cap the gateway sends no tool events")
    }

    func testTypedRequestUsesCurrentGatewayRPCEnvelope() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#
        let detected = #"{"type":"res","id":"detect-1","ok":true,"payload":{"setupComplete":false}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, accepted, detected])
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS 18.5.0", instanceID: "install-1"),
            requestID: RequestIDSequence(["connect-1", "detect-1"]).next)
        try await connection.connect()

        let result: SetupDetectionFixture = try await connection.request(
            method: "openclaw.setup.detect",
            params: EmptyGatewayParams())

        XCTAssertEqual(result, SetupDetectionFixture(setupComplete: false))
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "openclaw.setup.detect")
        XCTAssertNotNil(request["params"] as? [String: Any])
    }

    func testApprovalSubscriptionReplaysOnlyServerProvidedPendingApprovals() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#
        let replay = #"{"type":"res","id":"subscribe-1","ok":true,"payload":{"subscribed":true,"key":"agent:main:main","approvalReplay":{"sessionKey":"agent:main:main","updatedAtMs":1725000000123,"approvals":[{"id":"approval-exact-1","urlPath":"/approve/approval-exact-1","createdAtMs":1725000000000,"expiresAtMs":1725003600000,"status":"pending","presentation":{"kind":"exec","commandText":"git status","allowedDecisions":["allow-once","deny"]}}],"truncated":false}}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, accepted, replay])
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS 18.5.0", instanceID: "install-1"),
            requestID: RequestIDSequence(["connect-1", "subscribe-1"]).next)
        try await connection.connect()

        let result = try await connection.subscribeToSessionApprovals()

        XCTAssertEqual(result.approvals.map(\.id), ["approval-exact-1"])
        XCTAssertEqual(result.approvals.first?.presentation.allowedDecisions, [.allowOnce, .deny])
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "sessions.messages.subscribe")
        XCTAssertEqual(params["key"] as? String, "agent:main:main")
        XCTAssertEqual(params["includeApprovals"] as? Bool, true)
    }

    func testSessionApprovalEventAndCanonicalResolveSnapshotPreserveExactID() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let accepted = #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#
        let event = #"{"type":"event","event":"session.approval","payload":{"sessionKey":"agent:main:main","updatedAtMs":1725000000124,"phase":"pending","approval":{"id":"approval-exact-1","urlPath":"/approve/approval-exact-1","createdAtMs":1725000000000,"expiresAtMs":1725003600000,"status":"pending","presentation":{"kind":"exec","commandText":"git status","allowedDecisions":["allow-once","deny"]}}}}"#
        let resolved = #"{"type":"res","id":"resolve-1","ok":true,"payload":{"applied":true,"approval":{"id":"approval-exact-1","urlPath":"/approve/approval-exact-1","createdAtMs":1725000000000,"expiresAtMs":1725003600000,"resolvedAtMs":1725000000200,"reason":"user","status":"denied","decision":"deny","presentation":{"kind":"exec","commandText":"git status","allowedDecisions":["allow-once","deny"]}}}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, accepted, event, resolved])
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS 18.5.0", instanceID: "install-1"),
            requestID: RequestIDSequence(["connect-1", "resolve-1"]).next)
        try await connection.connect()

        let inbound = try await connection.receive()
        guard case let .approval(event) = inbound else {
            return XCTFail("Expected session.approval event")
        }
        let result = try await connection.resolveApproval(
            id: event.approval.id,
            kind: event.approval.presentation.kind,
            decision: .deny)

        XCTAssertEqual(event.approval.id, "approval-exact-1")
        XCTAssertEqual(result.approval.id, event.approval.id)
        XCTAssertEqual(result.approval.status, .denied)
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "approval.resolve")
        XCTAssertEqual(params["id"] as? String, "approval-exact-1")
        XCTAssertEqual(params["kind"] as? String, "exec")
        XCTAssertEqual(params["decision"] as? String, "deny")
    }

    func testRejectedConnectSurfacesGatewayErrorAndClosesTransport() async throws {
        let challenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let rejected = #"{"type":"res","id":"request-1","ok":false,"error":{"code":"AUTH_FAILED","message":"token rejected","retryable":false}}"#
        let transport = RecordingGatewayTransport(incoming: [challenge, rejected])
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "1.0", platform: "iOS 18.5.0", instanceID: "install-1"),
            requestID: RequestIDSequence(["request-1"]).next)

        do {
            try await connection.connect()
            XCTFail("connect should fail")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error, .rejected(code: "AUTH_FAILED", message: "token rejected"))
        }
        let closed = await transport.wasClosed()
        let connected = await connection.isConnected
        XCTAssertTrue(closed)
        XCTAssertFalse(connected)
    }

    func testConnectRetriesWhileExactDevicePairingIsBeingApproved() async throws {
        let firstChallenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#
        let notPaired = #"{"type":"res","id":"request-1","ok":false,"error":{"code":"NOT_PAIRED","message":"device pairing required","retryable":false}}"#
        let secondChallenge = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-2","ts":1725000001123}}"#
        let accepted = #"{"type":"res","id":"request-2","ok":true,"payload":{"status":"connected"}}"#
        let transport = RecordingGatewayTransport(
            incoming: [firstChallenge, notPaired, secondChallenge, accepted])
        let connection = OpenClawGatewayConnection(
            transport: transport,
            token: "local-token",
            identity: GatewayDeviceIdentity(),
            metadata: .init(
                appVersion: "1.0",
                platform: "iOS 18.5.0",
                instanceID: "install-1"),
            requestID: RequestIDSequence(["request-1", "request-2"]).next,
            pairingRetryDelay: {})

        try await connection.connect()

        let sent = await transport.sentMessages()
        let openCount = await transport.openCount()
        let connected = await connection.isConnected
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(openCount, 2)
        XCTAssertTrue(connected)
    }
}

private struct EmptyGatewayParams: Encodable, Sendable {}

private struct SetupDetectionFixture: Decodable, Equatable, Sendable {
    let setupComplete: Bool
}

private actor RecordingGatewayTransport: GatewayTransport {
    private var incoming: [Data]
    private var sent: [Data] = []
    private var closed = false
    private var opens = 0

    init(incoming: [String]) {
        self.incoming = incoming.map { Data($0.utf8) }
    }

    func open() async throws {
        self.opens += 1
    }

    func send(_ data: Data) async throws {
        self.sent.append(data)
    }

    func receive() async throws -> Data {
        guard !self.incoming.isEmpty else {
            throw TestTransportError.noMessage
        }
        return self.incoming.removeFirst()
    }

    func close() async {
        self.closed = true
    }

    func sentMessages() -> [Data] {
        self.sent
    }

    func wasClosed() -> Bool {
        self.closed
    }

    func openCount() -> Int {
        self.opens
    }
}

private enum TestTransportError: Error {
    case noMessage
}

private final class RequestIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.removeFirst()
    }
}
