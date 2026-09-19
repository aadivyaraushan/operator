import Foundation

struct NativeWhatsAppSendResult: Codable, Equatable, Sendable { let outcome: String; let messageId: String? }
enum NativeWhatsAppSendError: String, Error, Equatable { case invalidRequest = "invalid_request"; case notLinked = "not_linked"; case notAvailable = "not_available"; case invalidResponse }
protocol WhatsAppSendNativeBridge: Sendable { func send(store: String, recipientJID: String, body: String, timeoutMilliseconds: Int32) -> String }
struct CWhatsAppSendNativeBridge: WhatsAppSendNativeBridge {
    func send(store: String, recipientJID: String, body: String, timeoutMilliseconds: Int32) -> String { store.withCString { s in recipientJID.withCString { r in body.withCString { b in Self.consume(wacliSendText(s, r, b, timeoutMilliseconds)) } } } }
    private static func consume(_ value: UnsafeMutablePointer<CChar>?) -> String { guard let value else { return #"{"success":false,"error":{"code":"not_available"}}"# }; defer { sendWacliFreeString(value) }; return String(cString: value) }
}
@_silgen_name("WacliSendText") private func wacliSendText(_ store: UnsafePointer<CChar>, _ recipient: UnsafePointer<CChar>, _ body: UnsafePointer<CChar>, _ timeout: Int32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("WacliFreeString") private func sendWacliFreeString(_ value: UnsafeMutablePointer<CChar>)
private struct SendEnvelope: Decodable { struct Failure: Decodable { let code: String }; let success: Bool; let data: NativeWhatsAppSendResult?; let error: Failure? }
protocol WhatsAppTextSending: Sendable { func send(_ request: WhatsAppComposeRequest, timeoutMilliseconds: Int) async throws -> NativeWhatsAppSendResult }
actor NativeWhatsAppSendClient: WhatsAppTextSending {
    private let store: String; private let bridge: any WhatsAppSendNativeBridge
    init(supportDirectory: URL, bridge: any WhatsAppSendNativeBridge = CWhatsAppSendNativeBridge()) { store = supportDirectory.appendingPathComponent("Operator/whatsapp", isDirectory: true).path; self.bridge = bridge }
    func send(_ request: WhatsAppComposeRequest, timeoutMilliseconds: Int) throws -> NativeWhatsAppSendResult {
        let raw = bridge.send(store: store, recipientJID: request.recipientJID, body: request.body, timeoutMilliseconds: Int32(timeoutMilliseconds))
        guard let data = raw.data(using: .utf8), let envelope = try? JSONDecoder().decode(SendEnvelope.self, from: data) else { throw NativeWhatsAppSendError.invalidResponse }
        if envelope.success, let value = envelope.data, ["sent", "unknown"].contains(value.outcome) { return value }
        if let code = envelope.error?.code, let error = NativeWhatsAppSendError(rawValue: code) { throw error }
        throw NativeWhatsAppSendError.invalidResponse
    }
}
