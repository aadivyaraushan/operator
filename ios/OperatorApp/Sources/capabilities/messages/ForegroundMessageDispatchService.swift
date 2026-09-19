import Foundation
import OperatorCore
import OSLog

/// One intent - "text someone" - two ways out. The model asks for
/// `sms.compose`, which is the command it knows. If the owner has turned on
/// "Messages, sent for you" the message goes straight through the shortcut;
/// otherwise the system composer opens and the owner taps Send. Two separate
/// commands for one intent meant the model reached for the one it knew and the
/// shortcut never ran; the owner's grant, not the model's choice of verb, is
/// what should decide.
@MainActor
final class ForegroundMessageDispatchService: GatewayNodeCommandHandler {
    private let compose: any GatewayNodeCommandHandler
    private let send: any GatewayNodeCommandHandler
    private let autosendAllowed: @MainActor () -> Bool
    private let recordAutosend: @MainActor (_ command: String) -> Void
    private let logger = Logger(subsystem: "app.operator.ios", category: "message-dispatch")

    init(
        compose: any GatewayNodeCommandHandler,
        send: any GatewayNodeCommandHandler,
        autosendAllowed: @escaping @MainActor () -> Bool,
        recordAutosend: @escaping @MainActor (_ command: String) -> Void = { _ in })
    {
        self.compose = compose
        self.send = send
        self.autosendAllowed = autosendAllowed
        self.recordAutosend = recordAutosend
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        guard command == GatewayNativeNodeSurface.messageComposeCommand else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        // One person or a group of up to ten; more than that, or an odd shape,
        // still goes through the composer.
        guard self.autosendAllowed(), let sendParams = Self.sendParams(from: paramsJSON) else {
            return await self.compose.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        }
        self.logger.info("[message-dispatch] compose routed to send-for-you")
        // The gate already logged this as a Messages action; the session list
        // should also show that it went out without a tap.
        self.recordAutosend(GatewayNativeNodeSurface.messageSendCommand)
        return await self.send.handleNodeCommand(GatewayNativeNodeSurface.messageSendCommand, paramsJSON: sendParams, timeoutMilliseconds: timeoutMilliseconds)
    }

    static let groupLimit = 10

    /// `{"recipients":[one],"body":...}` becomes `{"recipient":one,"body":...}`
    /// and `{"recipients":[several],"body":...}` is passed through as is, up
    /// to `groupLimit` people. Anything else is nil and falls through to the
    /// composer, whose own validation then applies.
    static func sendParams(from paramsJSON: String?) -> String? {
        guard let paramsJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any],
              Set(object.keys) == ["recipients", "body"],
              let recipients = object["recipients"] as? [String], (1...Self.groupLimit).contains(recipients.count),
              let body = object["body"] as? String
        else { return nil }
        let params: [String: Any] = recipients.count == 1
            ? ["recipient": recipients[0], "body": body]
            : ["recipients": recipients, "body": body]
        guard let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
