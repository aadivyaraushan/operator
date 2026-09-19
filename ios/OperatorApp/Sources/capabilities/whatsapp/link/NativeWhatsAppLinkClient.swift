import Foundation
import OperatorCore

protocol WhatsAppNativeBridge: Sendable {
    func start(store: String, phone: String) -> String
    func status(operationID: String) -> String
    func cancel(operationID: String) -> String
}

enum NativeWhatsAppLinkError: String, Error, Equatable {
    case invalidRequest = "invalid_request"
    case linkInProgress = "link_in_progress"
    case linkFailed = "link_failed"
    case notAvailable = "not_available"
    case invalidResponse
}

private struct NativeWhatsAppEnvelope<Value: Decodable>: Decodable {
    struct Failure: Decodable { let code: String }
    let success: Bool
    let data: Value?
    let error: Failure?
}

struct CWhatsAppNativeBridge: WhatsAppNativeBridge {
    func start(store: String, phone: String) -> String {
        store.withCString { storePointer in
            phone.withCString { phonePointer in
                Self.consume(wacliStartLink(storePointer, phonePointer))
            }
        }
    }

    func status(operationID: String) -> String {
        operationID.withCString { Self.consume(wacliLinkStatus($0)) }
    }

    func cancel(operationID: String) -> String {
        operationID.withCString { Self.consume(wacliCancelLink($0)) }
    }

    private static func consume(_ value: UnsafeMutablePointer<CChar>?) -> String {
        guard let value else { return #"{"success":false,"error":{"code":"link_failed"}}"# }
        defer { wacliFreeString(value) }
        return String(cString: value)
    }
}

@_silgen_name("WacliStartLink")
private func wacliStartLink(_ store: UnsafePointer<CChar>, _ phone: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("WacliLinkStatus")
private func wacliLinkStatus(_ operationID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("WacliCancelLink")
private func wacliCancelLink(_ operationID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("WacliFreeString")
private func wacliFreeString(_ value: UnsafeMutablePointer<CChar>)

actor NativeWhatsAppLinkClient {
    private let storeDirectory: URL
    private let bridge: any WhatsAppNativeBridge
    private let decoder = JSONDecoder()

    init(supportDirectory: URL, bridge: any WhatsAppNativeBridge = CWhatsAppNativeBridge()) {
        self.init(
            storeDirectory: supportDirectory
                .appendingPathComponent("Operator", isDirectory: true)
                .appendingPathComponent("whatsapp", isDirectory: true),
            bridge: bridge)
    }

    init(storeDirectory: URL, bridge: any WhatsAppNativeBridge) {
        self.storeDirectory = storeDirectory
        self.bridge = bridge
    }

    func start(phone: String) throws -> WhatsAppLinkOperation {
        try self.prepareStore()
        return try self.decode(self.bridge.start(store: self.storeDirectory.path, phone: phone))
    }

    func status(operationID: String) throws -> WhatsAppLinkStatus {
        try self.decode(self.bridge.status(operationID: operationID))
    }

    func cancel(operationID: String) throws -> WhatsAppLinkOperation {
        try self.decode(self.bridge.cancel(operationID: operationID))
    }

    private func decode<Value: Decodable>(_ raw: String) throws -> Value {
        guard let data = raw.data(using: .utf8),
              let envelope = try? self.decoder.decode(NativeWhatsAppEnvelope<Value>.self, from: data)
        else { throw NativeWhatsAppLinkError.invalidResponse }
        if envelope.success, let value = envelope.data { return value }
        if let code = envelope.error?.code, let error = NativeWhatsAppLinkError(rawValue: code) { throw error }
        throw NativeWhatsAppLinkError.invalidResponse
    }

    private func prepareStore() throws {
        try FileManager.default.createDirectory(
            at: self.storeDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: self.storeDirectory.path)
    }
}

extension NativeWhatsAppLinkClient: WhatsAppLinkFlowGateway {}
