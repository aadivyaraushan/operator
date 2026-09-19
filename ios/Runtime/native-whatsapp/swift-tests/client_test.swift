import Foundation
import OperatorCore

private final class MockBridge: @unchecked Sendable, WhatsAppNativeBridge {
    private let lock = NSLock()
    private var responses: [String]
    private(set) var calls: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    func start(store: String, phone: String) -> String {
        self.next("start:\(store):\(phone)")
    }

    func status(operationID: String) -> String {
        self.next("status:\(operationID)")
    }

    func cancel(operationID: String) -> String {
        self.next("cancel:\(operationID)")
    }

    private func next(_ call: String) -> String {
        self.lock.withLock {
            self.calls.append(call)
            return self.responses.removeFirst()
        }
    }
}

private final class MockReadBridge: @unchecked Sendable, WhatsAppReadNativeBridge {
    let chatResponse: String
    let statusResponse: String
    private let lock = NSLock()
    private(set) var callCount = 0
    private(set) var cancelCount = 0
    init(chatResponse: String, statusResponse: String = #"{"success":true,"data":{"operationId":"sync-1","phase":"completed","messagesStored":2}}"#) {
        self.chatResponse = chatResponse; self.statusResponse = statusResponse
    }
    private func called(cancel: Bool = false) { lock.withLock { callCount += 1; if cancel { cancelCount += 1 } } }
    func start(store: String, phone: String) -> String { fatalError() }
    func chats(store: String, limit: Int32) -> String { called(); return chatResponse }
    func messages(store: String, chat: String, limit: Int32) -> String { called(); return #"{"success":true,"data":{"messages":[]}}"# }
    func startSync(store: String, timeoutSeconds: Int32) -> String { called(); return #"{"success":true,"data":{"operationId":"sync-1","phase":"syncing"}}"# }
    func syncStatus(operationID: String) -> String { called(); return statusResponse }
    func cancelSync(operationID: String) -> String { called(cancel: true); return #"{"success":true,"data":{"operationId":"sync-1","phase":"cancelled"}}"# }
}

@main
enum NativeWhatsAppLinkClientTests {
    static func main() async throws {
		let storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("native-whatsapp-swift-test-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let bridge = MockBridge([
            #"{"success":true,"data":{"operationId":"op-1","phase":"waiting_for_code"}}"#,
            #"{"success":true,"data":{"operationId":"op-1","phase":"code_ready","pairCode":"ABCD-1234"}}"#,
            #"{"success":true,"data":{"operationId":"op-1","phase":"cancelled"}}"#,
        ])
        let client = NativeWhatsAppLinkClient(storeDirectory: storeDirectory, bridge: bridge)
        let started = try await client.start(phone: "+14155550123")
        precondition(started.operationID == "op-1" && started.phase == .waitingForCode)
        let status = try await client.status(operationID: "op-1")
        precondition(status.phase == .codeReady && status.pairCode == "ABCD-1234")
        let cancelled = try await client.cancel(operationID: "op-1")
        precondition(cancelled.phase == .cancelled)
        precondition(bridge.calls == [
			"start:\(storeDirectory.path):+14155550123", "status:op-1", "cancel:op-1",
        ])
		let attributes = try FileManager.default.attributesOfItem(atPath: storeDirectory.path)
		precondition(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)

        let failedBridge = MockBridge([#"{"success":false,"error":{"code":"link_failed"}}"#])
        let failedClient = NativeWhatsAppLinkClient(storeDirectory: storeDirectory, bridge: failedBridge)
        do {
            _ = try await failedClient.start(phone: "+14155550123")
            preconditionFailure("sanitized native failure should throw")
        } catch let error as NativeWhatsAppLinkError {
            precondition(error == .linkFailed)
        }

        let readClient = NativeWhatsAppReadClient(supportDirectory: storeDirectory, bridge: MockReadBridge(
            chatResponse: #"{"success":true,"data":{"chats":[{"jid":"1@s.whatsapp.net","kind":"dm","name":"A","lastMessageAt":"2026-09-09T12:00:00Z","unreadCount":1}]}}"#))
        let chats = try await readClient.chats(limit: 1)
        let messages = try await readClient.messages(chat: "1@s.whatsapp.net", limit: 1)
        precondition(chats.first?.jid == "1@s.whatsapp.net")
        precondition(messages.isEmpty)
        let sync = try await readClient.startSync(timeoutSeconds: 10)
        precondition(sync.phase == "syncing")
        let completed = try await readClient.syncStatus(operationID: sync.operationId)
        let cancelledSync = try await readClient.cancelSync(operationID: sync.operationId)
        precondition(completed.messagesStored == 2)
        precondition(cancelledSync.phase == "cancelled")

        let guardedBridge = MockReadBridge(chatResponse: #"{"success":false,"error":{"code":"not_linked"}}"#)
        let guardedClient = NativeWhatsAppReadClient(supportDirectory: storeDirectory, bridge: guardedBridge)
        let service = await MainActor.run { ForegroundWhatsAppReadService(client: guardedClient, isAppActive: { true }) }
        for invalid in [
            #"{"url":"https://example.com"}"#, #"{"send":"hello"}"#, #"{"extra":1}"#,
            #"{"limit":"ten"}"#, #"{"limit":51}"#, "{",
        ] {
            let result = await service.handleNodeCommand("whatsapp.chats", paramsJSON: invalid, timeoutMilliseconds: 1_000)
            precondition(result == .failure(code: "INVALID_REQUEST", message: "WhatsApp parameters were invalid"))
        }
        precondition(guardedBridge.callCount == 0)
        let notLinked = await service.handleNodeCommand("whatsapp.chats", paramsJSON: #"{"limit":1}"#, timeoutMilliseconds: 1_000)
        precondition(notLinked == .failure(code: "WHATSAPP_NOT_LINKED", message: "Link WhatsApp in Operator first"))
        precondition(guardedBridge.callCount == 1)

        let inactiveBridge = MockReadBridge(chatResponse: #"{"success":true,"data":{"chats":[]}}"#)
        let inactiveClient = NativeWhatsAppReadClient(supportDirectory: storeDirectory, bridge: inactiveBridge)
        let inactive = await MainActor.run { ForegroundWhatsAppReadService(client: inactiveClient, isAppActive: { false }) }
        _ = await inactive.handleNodeCommand("whatsapp.messages", paramsJSON: #"{"chat":"1@s.whatsapp.net"}"#, timeoutMilliseconds: nil)
        precondition(inactiveBridge.callCount == 0)

        let syncingBridge = MockReadBridge(chatResponse: #"{"success":true,"data":{"chats":[]}}"#, statusResponse: #"{"success":true,"data":{"operationId":"sync-1","phase":"syncing"}}"#)
        let syncingClient = NativeWhatsAppReadClient(supportDirectory: storeDirectory, bridge: syncingBridge)
        let syncingService = await MainActor.run { ForegroundWhatsAppReadService(client: syncingClient, isAppActive: { true }) }
        let syncTask = Task { await syncingService.handleNodeCommand("whatsapp.sync", paramsJSON: "{}", timeoutMilliseconds: 10_000) }
        try await Task.sleep(for: .milliseconds(30)); syncTask.cancel(); _ = await syncTask.value
        try await Task.sleep(for: .milliseconds(30))
        precondition(syncingBridge.cancelCount == 1)
        print("NATIVE_WHATSAPP_SWIFT_CLIENT_PASS")
    }
}
