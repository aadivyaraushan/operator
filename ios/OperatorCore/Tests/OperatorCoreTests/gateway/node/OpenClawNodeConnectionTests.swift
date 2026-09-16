import Foundation
import XCTest
@testable import OperatorCore

final class OpenClawNodeConnectionTests: XCTestCase {
    func testPairingRejectionRunsOwnDeviceApprovalBeforeRetry() async throws {
        let transport = NodeRecordingTransport(incoming: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
            #"{"type":"res","id":"first","ok":false,"error":{"code":"NOT_PAIRED","message":"role upgrade required"}}"#,
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-2","ts":1725000000124}}"#,
            #"{"type":"res","id":"second","ok":true,"payload":{"status":"connected"}}"#,
        ])
        let approvals = NodeApprovalCounter()
        let connection = OpenClawNodeConnection(
            transport: transport, token: "token", identity: GatewayDeviceIdentity(), appVersion: "1",
            requestID: NodeRequestIDSequence(["first", "second", "tools-1"]).next,
            pairingRetryDelay: {}, approveOwnDeviceRole: { await approvals.record() })
        try await connection.connect()
        let count = await approvals.count
        XCTAssertEqual(count, 1)
    }
    func testConnectAdvertisesForegroundLocationAndCalendarAsAnIOSNode() async throws {
        let identity = GatewayDeviceIdentity()
        let transport = NodeRecordingTransport(incoming: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#,
        ])
        let connection = OpenClawNodeConnection(
            transport: transport,
            token: "local-token",
            identity: identity,
            appVersion: "1.0",
            platform: "ios",
            requestID: NodeRequestIDSequence(["connect-1", "tools-1"]).next)

        try await connection.connect()

        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[0]) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let client = try XCTUnwrap(params["client"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "connect")
        XCTAssertEqual(params["minProtocol"] as? Int, 3)
        XCTAssertEqual(params["maxProtocol"] as? Int, 4)
        XCTAssertEqual(params["role"] as? String, "node")
        XCTAssertEqual(params["scopes"] as? [String], [])
        XCTAssertEqual(params["caps"] as? [String], ["location", "calendar", "sms", "maps", "apps", "whatsapp", "accounts", "notion", "media", "reminders", "contacts", "photos", "music", "weather", "device", "discord"])
        XCTAssertEqual(params["commands"] as? [String], ["location.get", "calendar.events", "reminders.list", "contacts.search", "photos.latest", "music.nowPlaying", "music.search", "weather.forecast", "device.status", "sms.compose", "sms.send", "maps.search", "maps.directions", "apps.open", "whatsapp.chats", "whatsapp.messages", "whatsapp.sync", "whatsapp.compose", "connections.read", "connections.write", "connections.describe", "notion.tools", "notion.call", "youtube.search", "youtube.open", "podcasts.search", "podcasts.open", "discord.announcements", "messages.incoming"])
        XCTAssertEqual(client["id"] as? String, "node-host")
        XCTAssertEqual(client["mode"] as? String, "node")

        // Registering the commands is not enough on its own: without the
        // descriptors that follow, the gateway has the commands and the model
        // has no tools, so it never calls them.
        let published = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        XCTAssertEqual(published["method"] as? String, "node.pluginTools.update")
        let toolParams = try XCTUnwrap(published["params"] as? [String: Any])
        let tools = try XCTUnwrap(toolParams["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.compactMap { $0["command"] as? String },
            GatewayNodeAgentTools.publishedCommands)
        XCTAssertEqual(client["platform"] as? String, "ios")
        XCTAssertEqual(client["deviceFamily"] as? String, "iPhone")
        XCTAssertEqual(client["instanceId"] as? String, identity.deviceID)
    }

    func testInvocationReturnsMatchingOpenClawResultEnvelope() async throws {
        let identity = GatewayDeviceIdentity()
        let invoke = """
        {"type":"event","event":"node.invoke.request","payload":{"id":"invoke-1","nodeId":"\(identity.deviceID)","command":"location.get","paramsJSON":"{\\"desiredAccuracy\\":\\"precise\\"}","timeoutMs":10000,"idempotencyKey":"location-1"}}
        """
        let transport = NodeRecordingTransport(incoming: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#,
            invoke,
            #"{"type":"res","id":"result-1","ok":true,"payload":{"ok":true}}"#,
        ])
        let handler = RecordingNodeHandler(result: .success(
            payloadJSON: #"{"accuracyMeters":12,"isPrecise":true,"lat":40.1,"lon":-88.2,"timestamp":"2026-09-04T18:00:00Z"}"#))
        let connection = OpenClawNodeConnection(
            transport: transport,
            token: "local-token",
            identity: identity,
            appVersion: "1.0",
            platform: "ios",
            requestID: NodeRequestIDSequence(["connect-1", "tools-1", "result-1"]).next)
        try await connection.connect()

        try await connection.receiveAndHandleNext(using: handler)

        let invocations = await handler.invocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].command, "location.get")
        XCTAssertEqual(invocations[0].timeoutMilliseconds, 10000)
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(firstSentRequest(in: sent, method: "node.invoke.result"))
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "node.invoke.result")
        XCTAssertEqual(params["id"] as? String, "invoke-1")
        XCTAssertEqual(params["nodeId"] as? String, identity.deviceID)
        XCTAssertEqual(params["ok"] as? Bool, true)
        XCTAssertNotNil(params["payloadJSON"] as? String)
    }

    func testCalendarInvocationReturnsMatchingOpenClawResultEnvelope() async throws {
        let identity = GatewayDeviceIdentity()
        let invoke = """
        {"type":"event","event":"node.invoke.request","payload":{"id":"invoke-1","nodeId":"\(identity.deviceID)","command":"calendar.events","paramsJSON":"{}","timeoutMs":10000,"idempotencyKey":"calendar-1"}}
        """
        let transport = NodeRecordingTransport(incoming: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#,
            invoke,
            #"{"type":"res","id":"result-1","ok":true,"payload":{"ok":true}}"#,
        ])
        let handler = RecordingNodeHandler(result: .success(payloadJSON: #"{"events":[]}"#))
        let connection = OpenClawNodeConnection(
            transport: transport,
            token: "local-token",
            identity: identity,
            appVersion: "1.0",
            platform: "ios",
            requestID: NodeRequestIDSequence(["connect-1", "tools-1", "result-1"]).next)
        try await connection.connect()

        try await connection.receiveAndHandleNext(using: handler)

        let invocations = await handler.invocations()
        XCTAssertEqual(invocations.map(\.command), ["calendar.events"])
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(firstSentRequest(in: sent, method: "node.invoke.result"))
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["ok"] as? Bool, true)
        XCTAssertEqual(params["payloadJSON"] as? String, #"{"events":[]}"#)
    }

    // sms.send is a registered command since the owner can grant "Messages,
    // sent for you"; whether it may run is decided by the app's permission
    // gate, not here. A command the node never registered is still refused
    // before any handler sees it.
    func testRegisteredMessageCommandsAreForwardedAndUnregisteredOnesRejected() async throws {
        for command in ["sms.compose", "sms.delete"] {
            let identity = GatewayDeviceIdentity()
            let body = #"{"recipients":["+15555550100"],"body":"Test draft"}"#
            let event = try JSONSerialization.data(withJSONObject: [
                "type": "event", "event": "node.invoke.request",
                "payload": ["id": "invoke-1", "nodeId": identity.deviceID,
                            "command": command, "paramsJSON": body, "timeoutMs": 10000,
                            "idempotencyKey": "compose-1"],
            ])
            let transport = NodeRecordingTransport(incoming: [
                #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
                #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#,
                String(decoding: event, as: UTF8.self),
                #"{"type":"res","id":"result-1","ok":true,"payload":{"ok":true}}"#,
            ])
            let result = #"{"presented":true,"sent":false,"deliveryVerified":false,"requiresUserSend":true}"#
            let handler = RecordingNodeHandler(result: .success(payloadJSON: result))
            let connection = OpenClawNodeConnection(
                transport: transport, token: "local-token", identity: identity,
                appVersion: "1.0", platform: "ios",
                requestID: NodeRequestIDSequence(["connect-1", "tools-1", "result-1"]).next)
            try await connection.connect()
            try await connection.receiveAndHandleNext(using: handler)
            let invocations = await handler.invocations()
            XCTAssertEqual(invocations.map(\.command), command == "sms.compose" ? [command] : [])
            let sent = await transport.sentMessages()
            let request = try XCTUnwrap(firstSentRequest(in: sent, method: "node.invoke.result"))
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["ok"] as? Bool, command == "sms.compose")
            if command == "sms.compose" {
                XCTAssertEqual(params["payloadJSON"] as? String, result)
            } else {
                let error = try XCTUnwrap(params["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, "UNSUPPORTED_COMMAND")
            }
        }
    }

    func testUnknownCommandFailsClosedWithoutCallingNativeHandler() async throws {
        let identity = GatewayDeviceIdentity()
        let invoke = """
        {"type":"event","event":"node.invoke.request","payload":{"id":"invoke-1","nodeId":"\(identity.deviceID)","command":"camera.snap","paramsJSON":"{}","timeoutMs":10000,"idempotencyKey":"camera-1"}}
        """
        let transport = NodeRecordingTransport(incoming: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#,
            invoke,
            #"{"type":"res","id":"result-1","ok":true,"payload":{"ok":true}}"#,
        ])
        let handler = RecordingNodeHandler(result: .success(payloadJSON: "{}"))
        let connection = OpenClawNodeConnection(
            transport: transport,
            token: "local-token",
            identity: identity,
            appVersion: "1.0",
            platform: "ios",
            requestID: NodeRequestIDSequence(["connect-1", "tools-1", "result-1"]).next)
        try await connection.connect()

        try await connection.receiveAndHandleNext(using: handler)

        let invocationCount = await handler.invocations().count
        XCTAssertEqual(invocationCount, 0)
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(firstSentRequest(in: sent, method: "node.invoke.result"))
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let error = try XCTUnwrap(params["error"] as? [String: Any])
        XCTAssertEqual(params["ok"] as? Bool, false)
        XCTAssertEqual(error["code"] as? String, "UNSUPPORTED_COMMAND")
    }

    func testMalformedParamsFailClosedWithoutCallingNativeHandler() async throws {
        let identity = GatewayDeviceIdentity()
        let invoke = """
        {"type":"event","event":"node.invoke.request","payload":{"id":"invoke-1","nodeId":"\(identity.deviceID)","command":"location.get","paramsJSON":"not-json","timeoutMs":10000,"idempotencyKey":"location-1"}}
        """
        let transport = NodeRecordingTransport(incoming: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1725000000123}}"#,
            #"{"type":"res","id":"connect-1","ok":true,"payload":{"status":"connected"}}"#,
            invoke,
            #"{"type":"res","id":"result-1","ok":true,"payload":{"ok":true}}"#,
        ])
        let handler = RecordingNodeHandler(result: .success(payloadJSON: "{}"))
        let connection = OpenClawNodeConnection(
            transport: transport,
            token: "local-token",
            identity: identity,
            appVersion: "1.0",
            platform: "ios",
            requestID: NodeRequestIDSequence(["connect-1", "tools-1", "result-1"]).next)
        try await connection.connect()

        try await connection.receiveAndHandleNext(using: handler)

        let invocationCount = await handler.invocations().count
        XCTAssertEqual(invocationCount, 0)
        let sent = await transport.sentMessages()
        let request = try XCTUnwrap(firstSentRequest(in: sent, method: "node.invoke.result"))
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let error = try XCTUnwrap(params["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "INVALID_REQUEST")
    }
}

private actor NodeApprovalCounter {
    var count = 0
    func record() { count += 1 }
}

private actor RecordingNodeHandler: GatewayNodeCommandHandler {
    struct Invocation: Equatable, Sendable {
        let command: String
        let paramsJSON: String?
        let timeoutMilliseconds: Int?
    }

    private let result: GatewayNodeCommandResult
    private var received: [Invocation] = []

    init(result: GatewayNodeCommandResult) {
        self.result = result
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        self.received.append(Invocation(
            command: command,
            paramsJSON: paramsJSON,
            timeoutMilliseconds: timeoutMilliseconds))
        return self.result
    }

    func invocations() -> [Invocation] {
        self.received
    }
}

/// Look a frame up by what it is rather than by where it landed. These
/// assertions used to index into the sent list, so publishing agent tools on
/// connect quietly pointed them at the wrong request.
private func firstSentRequest(in frames: [Data], method: String) -> [String: Any]? {
    for frame in frames {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
        if object["method"] as? String == method { return object }
    }
    return nil
}

private actor NodeRecordingTransport: GatewayTransport {
    private var incoming: [Data]
    private var sent: [Data] = []

    init(incoming: [String]) {
        self.incoming = incoming.map { Data($0.utf8) }
    }

    func open() async throws {}

    func send(_ data: Data) async throws {
        self.sent.append(data)
    }

    func receive() async throws -> Data {
        guard !self.incoming.isEmpty else { throw NodeTransportError.noMessage }
        return self.incoming.removeFirst()
    }

    func close() async {}

    func sentMessages() -> [Data] {
        self.sent
    }
}

private enum NodeTransportError: Error {
    case noMessage
}

private final class NodeRequestIDSequence: @unchecked Sendable {
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
