import Foundation

struct NativeWhatsAppChat: Codable, Equatable, Sendable {
    let jid: String
    let kind: String
    let name: String
    let lastMessageAt: Date
    let unreadCount: Int
}

struct NativeWhatsAppMessage: Codable, Equatable, Sendable {
    let chatJid: String
    let messageId: String
    let senderJid: String
    let senderName: String?
    let timestamp: Date
    let fromMe: Bool
    let text: String
    let type: String?
}

struct NativeWhatsAppSyncStatus: Codable, Equatable, Sendable {
    let operationId: String
    let phase: String
    let messagesStored: Int64?
}

protocol WhatsAppReadNativeBridge: Sendable {
    func chats(store: String, limit: Int32) -> String
    func messages(store: String, chat: String, limit: Int32) -> String
    func startSync(store: String, timeoutSeconds: Int32) -> String
    func syncStatus(operationID: String) -> String
    func cancelSync(operationID: String) -> String
}

enum NativeWhatsAppReadError: String, Error, Equatable {
    case invalidRequest = "invalid_request"
    case notLinked = "not_linked"
    case notAvailable = "not_available"
    case syncInProgress = "sync_in_progress"
    case invalidResponse
}

private struct ReadEnvelope<Value: Decodable>: Decodable {
    struct Failure: Decodable { let code: String }
    let success: Bool
    let data: Value?
    let error: Failure?
}

private struct ChatPayload: Codable { let chats: [NativeWhatsAppChat] }
private struct MessagePayload: Codable { let messages: [NativeWhatsAppMessage] }

struct CWhatsAppReadNativeBridge: WhatsAppReadNativeBridge {
    func chats(store: String, limit: Int32) -> String {
        store.withCString { Self.consume(wacliListChats($0, limit)) }
    }
    func messages(store: String, chat: String, limit: Int32) -> String {
        store.withCString { storePointer in chat.withCString { Self.consume(wacliListMessages(storePointer, $0, limit)) } }
    }
    func startSync(store: String, timeoutSeconds: Int32) -> String {
        store.withCString { Self.consume(wacliStartSync($0, timeoutSeconds)) }
    }
    func syncStatus(operationID: String) -> String { operationID.withCString { Self.consume(wacliSyncStatus($0)) } }
    func cancelSync(operationID: String) -> String { operationID.withCString { Self.consume(wacliCancelSync($0)) } }
    private static func consume(_ value: UnsafeMutablePointer<CChar>?) -> String {
        guard let value else { return #"{"success":false,"error":{"code":"not_available"}}"# }
        defer { readWacliFreeString(value) }
        return String(cString: value)
    }
}

@_silgen_name("WacliListChats") private func wacliListChats(_ store: UnsafePointer<CChar>, _ limit: Int32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("WacliListMessages") private func wacliListMessages(_ store: UnsafePointer<CChar>, _ chat: UnsafePointer<CChar>, _ limit: Int32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("WacliStartSync") private func wacliStartSync(_ store: UnsafePointer<CChar>, _ timeoutSeconds: Int32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("WacliSyncStatus") private func wacliSyncStatus(_ operationID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("WacliCancelSync") private func wacliCancelSync(_ operationID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("WacliFreeString") private func readWacliFreeString(_ value: UnsafeMutablePointer<CChar>)

actor NativeWhatsAppReadClient {
    private let store: String
    private let bridge: any WhatsAppReadNativeBridge
    private let decoder: JSONDecoder

    init(supportDirectory: URL, bridge: any WhatsAppReadNativeBridge = CWhatsAppReadNativeBridge()) {
        self.store = supportDirectory.appendingPathComponent("Operator/whatsapp", isDirectory: true).path
        self.bridge = bridge
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func chats(limit: Int) throws -> [NativeWhatsAppChat] {
        let payload: ChatPayload = try self.decode(self.bridge.chats(store: self.store, limit: Int32(limit)))
        return payload.chats
    }
    func messages(chat: String, limit: Int) throws -> [NativeWhatsAppMessage] {
        let payload: MessagePayload = try self.decode(self.bridge.messages(store: self.store, chat: chat, limit: Int32(limit)))
        return payload.messages
    }
    func startSync(timeoutSeconds: Int) throws -> NativeWhatsAppSyncStatus {
        try self.decode(self.bridge.startSync(store: self.store, timeoutSeconds: Int32(timeoutSeconds)))
    }
    func syncStatus(operationID: String) throws -> NativeWhatsAppSyncStatus { try self.decode(self.bridge.syncStatus(operationID: operationID)) }
    func cancelSync(operationID: String) throws -> NativeWhatsAppSyncStatus { try self.decode(self.bridge.cancelSync(operationID: operationID)) }

    private func decode<Value: Decodable>(_ raw: String) throws -> Value {
        guard let data = raw.data(using: .utf8), let envelope = try? self.decoder.decode(ReadEnvelope<Value>.self, from: data) else { throw NativeWhatsAppReadError.invalidResponse }
        if envelope.success, let value = envelope.data { return value }
        if let code = envelope.error?.code, let error = NativeWhatsAppReadError(rawValue: code) { throw error }
        throw NativeWhatsAppReadError.invalidResponse
    }
}
