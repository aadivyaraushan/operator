import Foundation
import OperatorCore
import OSLog
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ForegroundWhatsAppReadService: GatewayNodeCommandHandler {
    private struct LimitParameters: Decodable { let limit: Int? }
    private struct MessageParameters: Decodable { let chat: String; let limit: Int? }
    private struct SyncParameters: Decodable { let timeoutSeconds: Int? }
    private struct ChatPayload: Encodable { let chats: [NativeWhatsAppChat] }
    private struct MessagePayload: Encodable { let messages: [NativeWhatsAppMessage] }

    private let client: NativeWhatsAppReadClient
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-whatsapp")

    init(client: NativeWhatsAppReadClient, isAppActive: @escaping @MainActor @Sendable () -> Bool = {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }) { self.client = client; self.isAppActive = isAppActive }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        self.logger.debug("[whatsapp-read] request command=\(command, privacy: .public) hasParams=\(paramsJSON != nil) timeoutProvided=\(timeoutMilliseconds != nil)")
        guard ["whatsapp.chats", "whatsapp.messages", "whatsapp.sync"].contains(command) else { return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)") }
        guard self.isAppActive() else {
            self.logger.info("[whatsapp-read] rejected inactive command=\(command, privacy: .public)")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use WhatsApp")
        }
        do {
            switch command {
            case "whatsapp.chats":
                let parameters: LimitParameters = try Self.parameters(paramsJSON, allowedKeys: ["limit"])
                let limit = parameters.limit ?? 20; guard (1...50).contains(limit) else { throw NativeWhatsAppReadError.invalidRequest }
                self.logger.debug("[whatsapp-read] branch=chats limit=\(limit)")
                let chats = try await self.client.chats(limit: limit)
                self.logger.info("[whatsapp-read] completed branch=chats count=\(chats.count)")
                return try Self.encoded(ChatPayload(chats: chats))
            case "whatsapp.messages":
                let parameters: MessageParameters = try Self.parameters(paramsJSON, allowedKeys: ["chat", "limit"])
                let limit = parameters.limit ?? 20; guard (1...50).contains(limit), !parameters.chat.isEmpty, parameters.chat.count <= 256 else { throw NativeWhatsAppReadError.invalidRequest }
                self.logger.debug("[whatsapp-read] branch=messages limit=\(limit)")
                let messages = try await self.client.messages(chat: parameters.chat, limit: limit)
                self.logger.info("[whatsapp-read] completed branch=messages count=\(messages.count)")
                return try Self.encoded(MessagePayload(messages: messages))
            default:
                let parameters: SyncParameters = try Self.parameters(paramsJSON, allowedKeys: ["timeoutSeconds"])
                let requested = parameters.timeoutSeconds ?? 30
                let nodeLimit = max(1, min(60, (timeoutMilliseconds ?? 30_000) / 1_000))
                let seconds = min(requested, nodeLimit); guard (1...60).contains(seconds) else { throw NativeWhatsAppReadError.invalidRequest }
                self.logger.debug("[whatsapp-read] branch=sync timeoutSeconds=\(seconds)")
                return await self.sync(seconds: seconds)
            }
        } catch let error as NativeWhatsAppReadError {
            self.logger.info("[whatsapp-read] rejected errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return Self.failure(error)
        } catch {
            self.logger.error("[whatsapp-read] failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return .failure(code: "WHATSAPP_UNAVAILABLE", message: "WhatsApp could not complete this request")
        }
    }

    private func sync(seconds: Int) async -> GatewayNodeCommandResult {
        do {
            let started = try await self.client.startSync(timeoutSeconds: seconds)
            return try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    let status = try await self.client.syncStatus(operationID: started.operationId)
                    switch status.phase {
                    case "syncing": try await Task.sleep(for: .milliseconds(200))
                    case "completed":
                        self.logger.info("[whatsapp-read] completed branch=sync count=\(status.messagesStored ?? 0)")
                        return try Self.encoded(status)
                    case "not_linked": return Self.failure(.notLinked)
                    case "cancelled": return .failure(code: "CANCELLED", message: "WhatsApp sync was cancelled")
                    default: return .failure(code: "WHATSAPP_UNAVAILABLE", message: "WhatsApp sync did not complete")
                    }
                }
            } onCancel: { Task { _ = try? await self.client.cancelSync(operationID: started.operationId) } }
        } catch is CancellationError {
            self.logger.info("[whatsapp-read] cancelled branch=sync")
            return .failure(code: "CANCELLED", message: "WhatsApp sync was cancelled")
        } catch let error as NativeWhatsAppReadError {
            self.logger.info("[whatsapp-read] sync rejected errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return Self.failure(error)
        } catch {
            self.logger.error("[whatsapp-read] sync failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            return .failure(code: "WHATSAPP_UNAVAILABLE", message: "WhatsApp sync did not complete")
        }
    }

    private static func parameters<Value: Decodable>(_ raw: String?, allowedKeys: Set<String>) throws -> Value {
        let data = Data((raw ?? "{}").utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: allowedKeys),
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else { throw NativeWhatsAppReadError.invalidRequest }
        return value
    }
    private static func encoded<Value: Encodable>(_ value: Value) throws -> GatewayNodeCommandResult {
        .success(payloadJSON: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
    private static func failure(_ error: NativeWhatsAppReadError) -> GatewayNodeCommandResult {
        switch error {
        case .invalidRequest: .failure(code: "INVALID_REQUEST", message: "WhatsApp parameters were invalid")
        case .notLinked: .failure(code: "WHATSAPP_NOT_LINKED", message: "Link WhatsApp in Operator first")
        default: .failure(code: "WHATSAPP_UNAVAILABLE", message: "WhatsApp could not complete this request")
        }
    }
}
