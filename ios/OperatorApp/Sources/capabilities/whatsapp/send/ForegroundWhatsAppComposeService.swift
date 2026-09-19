import Foundation
import OperatorCore
import OSLog

struct WhatsAppComposeRequest: Codable, Equatable, Sendable { let recipientJID: String; let body: String }
enum WhatsAppComposeDecision: Sendable { case confirmed(WhatsAppComposeRequest); case denied }
@MainActor protocol WhatsAppComposePresenter: AnyObject, Sendable { func confirm(_ request: WhatsAppComposeRequest) async -> WhatsAppComposeDecision; func cancel() }
/// The display name for a chat JID, from the local WhatsApp store.
protocol WhatsAppRecipientNaming: Sendable { func name(forJID jid: String) async -> String? }
/// What the model gets back when the question went out as a notification
/// instead of an alert: nothing has been sent, and it must not try again.
struct WhatsAppComposeAskedPayload: Codable, Equatable, Sendable {
    let outcome: String
    let sent: Bool
    let askedByNotification: Bool
    let recipientName: String
    let expiresInSeconds: Int
    let note: String
    init(recipientName: String) {
        self.outcome = "asked"
        self.sent = false
        self.askedByNotification = true
        self.recipientName = recipientName
        self.expiresInSeconds = Int(PendingSendStore.expiry)
        self.note = "Operator is working in the background, so the person got a notification with Send and Don't send. Nothing has been sent. Tell them the message to \(recipientName) is waiting in a notification, and do not call whatsapp.compose again for it."
    }
}
@MainActor final class ForegroundWhatsAppComposeService: GatewayNodeCommandHandler {
    private enum Confirmation: Sendable { case decision(WhatsAppComposeDecision); case timedOut }
    private let presenter: any WhatsAppComposePresenter; private let sender: any WhatsAppTextSending
    /// Whether the app is on screen, where an alert can be shown. Off screen
    /// with `confirmations` set, the question goes out as a notification.
    private let isAppActive: @MainActor @Sendable () -> Bool
    /// Nil only in tests of the confirmation flow itself; the app always supplies one.
    private let guardrail: WhatsAppSendGuard?
    private let confirmations: PendingSendCenter?
    private let names: (any WhatsAppRecipientNaming)?
    private let logger = Logger(subsystem: "app.operator.ios", category: "whatsapp-compose")
    init(presenter: any WhatsAppComposePresenter, sender: any WhatsAppTextSending, isAppActive: @escaping @MainActor @Sendable () -> Bool, guardrail: WhatsAppSendGuard? = nil, confirmations: PendingSendCenter? = nil, names: (any WhatsAppRecipientNaming)? = nil) { self.presenter = presenter; self.sender = sender; self.isAppActive = isAppActive; self.guardrail = guardrail; self.confirmations = confirmations; self.names = names }
    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        guard command == "whatsapp.compose" else { return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)") }
        guard let request = Self.parameters(paramsJSON) else { logger.info("[whatsapp-compose] rejected branch=invalid-request"); return .failure(code: "INVALID_REQUEST", message: "whatsapp.compose requires only recipientJID and body") }
        guard isAppActive() else {
            guard let confirmations else { logger.info("[whatsapp-compose] rejected branch=inactive"); return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to confirm the WhatsApp message") }
            return await self.askByNotification(request, through: confirmations)
        }
        // Refused before the owner is even asked: a stranger or a burst is
        // refused whether or not the owner would have tapped Send.
        if let guardrail, let refusal = await guardrail.check(recipientJID: request.recipientJID) { return .failure(code: refusal.code, message: refusal.message) }
        let milliseconds = max(1, min(timeoutMilliseconds ?? 30_000, 30_000))
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1_000)
        logger.info("[whatsapp-compose] awaiting-owner-confirmation recipientBytes=\(request.recipientJID.utf8.count) bodyBytes=\(request.body.utf8.count) timeoutMilliseconds=\(milliseconds)")
        switch await confirm(request, milliseconds: milliseconds) {
        case .timedOut: logger.info("[whatsapp-compose] rejected branch=timeout"); return .failure(code: "TIMEOUT", message: "WhatsApp confirmation timed out")
        case let .decision(.confirmed(confirmed)) where confirmed == request: break
        case .decision(.confirmed): presenter.cancel(); logger.error("[whatsapp-compose] rejected branch=confirmation-mismatch"); return .failure(code: "CONFIRMATION_MISMATCH", message: "WhatsApp message was not sent")
        case .decision(.denied): logger.info("[whatsapp-compose] rejected branch=owner-denied"); return .failure(code: "OWNER_DENIED", message: "WhatsApp message was not sent")
        }
        guard isAppActive(), !Task.isCancelled else { presenter.cancel(); logger.info("[whatsapp-compose] rejected branch=inactive-after-confirmation"); return .failure(code: "APP_NOT_ACTIVE", message: "WhatsApp message was not sent") }
        let remainingMilliseconds = Int(deadline.timeIntervalSinceNow * 1_000)
        guard remainingMilliseconds > 0 else { presenter.cancel(); return .failure(code: "TIMEOUT", message: "WhatsApp confirmation timed out") }
        do {
            let result = try await sender.send(request, timeoutMilliseconds: remainingMilliseconds)
            guardrail?.recordSend()
            logger.info("[whatsapp-compose] completed outcome=\(result.outcome, privacy: .public)")
            return try .success(payloadJSON: String(decoding: JSONEncoder().encode(result), as: UTF8.self))
        } catch let error as NativeWhatsAppSendError {
            logger.error("[whatsapp-compose] failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            switch error { case .invalidRequest: return .failure(code: "INVALID_REQUEST", message: "WhatsApp parameters were invalid"); case .notLinked: return .failure(code: "WHATSAPP_NOT_LINKED", message: "Link WhatsApp in Operator first"); default: return .failure(code: "WHATSAPP_UNAVAILABLE", message: "WhatsApp could not complete this request") }
        } catch { logger.error("[whatsapp-compose] failed errorType=\(String(reflecting: type(of: error)), privacy: .public)"); return .failure(code: "WHATSAPP_UNAVAILABLE", message: "WhatsApp could not complete this request") }
    }
    /// Off screen: the center runs the guard, holds the draft and posts the
    /// question. The tool result says so in words the model cannot mistake
    /// for a send.
    private func askByNotification(_ request: WhatsAppComposeRequest, through confirmations: PendingSendCenter) async -> GatewayNodeCommandResult {
        let name = await self.names?.name(forJID: request.recipientJID) ?? Self.fallbackName(forJID: request.recipientJID)
        switch await confirmations.ask(request, recipientName: name) {
        case let .refused(refusal):
            logger.info("[whatsapp-compose] rejected branch=guard-off-screen code=\(refusal.code, privacy: .public)")
            return .failure(code: refusal.code, message: refusal.message)
        case .asked:
            logger.info("[whatsapp-compose] asked-by-notification recipientBytes=\(request.recipientJID.utf8.count) bodyBytes=\(request.body.utf8.count)")
            let payload = WhatsAppComposeAskedPayload(recipientName: name)
            guard let json = try? String(decoding: JSONEncoder().encode(payload), as: UTF8.self) else { return .failure(code: "WHATSAPP_UNAVAILABLE", message: "WhatsApp could not complete this request") }
            return .success(payloadJSON: json)
        }
    }
    /// When the store has no name: the number for a person, "a group" for a
    /// group, otherwise the JID itself. The notification must say who the
    /// message is for even when the name is unknown.
    static func fallbackName(forJID jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        let user = String(jid[..<at]); let host = jid[jid.index(after: at)...]
        if host == "g.us" { return "a group" }
        if host == "s.whatsapp.net", !user.isEmpty, user.allSatisfy(\.isNumber) { return "+\(user)" }
        return jid
    }
    private func confirm(_ request: WhatsAppComposeRequest, milliseconds: Int) async -> Confirmation {
        await withTaskGroup(of: Confirmation.self) { group in
            group.addTask { @MainActor @Sendable [presenter] in .decision(await presenter.confirm(request)) }
            group.addTask { try? await Task.sleep(for: .milliseconds(milliseconds)); return .timedOut }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            // UIKit confirmation waits for a button or an explicit cancellation;
            // cancelling the task alone cannot release its continuation.
            if case .timedOut = first { presenter.cancel() }
            return first
        }
    }
    private static func parameters(_ raw: String?) -> WhatsAppComposeRequest? {
        guard let raw, let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], Set(object.keys) == ["recipientJID", "body"], let recipient = object["recipientJID"] as? String, let body = object["body"] as? String, !recipient.isEmpty, recipient.utf8.count <= 256, !body.isEmpty, body.utf8.count <= 16*1024 else { return nil }
        return .init(recipientJID: recipient, body: body)
    }
}
