import Foundation
import OperatorCore
import OSLog
import UIKit

/// Opens a URL that runs the owner's shortcut. Abstracted so the URL and the
/// refusals can be tested without launching Shortcuts.
@MainActor
protocol ShortcutRunner: AnyObject {
    func run(_ url: URL) async -> Bool
}

@MainActor
final class SystemShortcutRunner: ShortcutRunner {
    func run(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url) { continuation.resume(returning: $0) }
        }
    }
}

/// `sms.send`: a text or iMessage with no confirmation tap.
///
/// iOS gives a third-party app no way to send a message itself; the only
/// on-device route is the Shortcuts app, whose Send Message action sends
/// without asking when the owner turns "Show When Run" off in a shortcut they
/// build. Operator hands the shortcut `{"to","body"}` as text over
/// x-callback-url and comes back when it finishes. So this service can say
/// the shortcut was started; it can never say the message arrived, and its
/// payload is written so the model cannot claim otherwise.
@MainActor
final class ForegroundMessageSendService: GatewayNodeCommandHandler {
    static let shortcutName = "Operator Send Message"
    static let callbackScheme = "app.operator.ios"
    static let callbackHost = "shortcut"

    /// The signed shortcut file, built and signed with `shortcuts sign --mode
    /// anyone` on a Mac and checked in beside the app. Served from the public
    /// repository so Shortcuts can fetch it; a Shortcuts import needs an https
    /// URL, and unsigned files are refused since iOS 15.
    static let signedShortcutURL = URL(string:
        "https://raw.githubusercontent.com/aadivyaraushan/operator/codex/ios-connectors/ios/OperatorApp/Resources/shortcuts/Operator%20Send%20Message.shortcut")!

    /// Opens Shortcuts on its import preview for the signed file; one tap on
    /// "Add Shortcut" there installs it under the exact name sms.send runs.
    static var installURL: URL {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "import-shortcut"
        components.queryItems = [
            .init(name: "url", value: self.signedShortcutURL.absoluteString),
            .init(name: "name", value: self.shortcutName),
            .init(name: "silent", value: "true"),
        ]
        return components.url!
    }

    private struct Parameters {
        let recipient: String
        let body: String
    }

    private let runner: any ShortcutRunner
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "message-send")

    init(runner: any ShortcutRunner, isAppActive: @escaping @MainActor @Sendable () -> Bool) {
        self.runner = runner
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult {
        guard command == GatewayNativeNodeSurface.messageSendCommand else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let parameters = Self.parameters(from: paramsJSON) else {
            self.logger.info("[message-send] rejected invalid request shape")
            return .failure(code: "INVALID_REQUEST", message: "sms.send requires exactly one nonempty recipient and a nonempty body")
        }
        guard self.isAppActive() else {
            self.logger.info("[message-send] rejected while app inactive")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to send a message")
        }
        guard let url = Self.shortcutURL(recipient: parameters.recipient, body: parameters.body) else {
            return .failure(code: "INVALID_REQUEST", message: "The message could not be encoded for the shortcut")
        }
        guard await self.runner.run(url) else {
            self.logger.info("[message-send] shortcut could not be opened")
            return .failure(
                code: "SHORTCUT_UNAVAILABLE",
                message: "The \"\(Self.shortcutName)\" shortcut could not be opened. The person has to create it once in the Shortcuts app; the steps are on Operator's Permissions page under \"\(ConnectorCatalog.descriptor(.messagesAutosend).title)\". Nothing was sent.")
        }
        self.logger.info("[message-send] handed to shortcut body_bytes=\(parameters.body.utf8.count)")
        return .success(payloadJSON: """
        {"handedToShortcut":true,"sent":false,"deliveryVerified":false,"nextStep":"The message was handed to the person's \\"\(Self.shortcutName)\\" shortcut, which sends it without asking them. Say it was handed off for sending; do not say it was delivered, because that is not known."}
        """)
    }

    /// shortcuts://x-callback-url/run-shortcut, with the message as a JSON
    /// text input and Operator's own scheme as the return address.
    static func shortcutURL(recipient: String, body: String) -> URL? {
        guard let input = try? JSONSerialization.data(withJSONObject: ["to": recipient, "body": body], options: [.sortedKeys]),
              let text = String(data: input, encoding: .utf8)
        else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            .init(name: "name", value: self.shortcutName),
            .init(name: "input", value: "text"),
            .init(name: "text", value: text),
            .init(name: "x-success", value: "\(self.callbackScheme)://\(self.callbackHost)/success"),
            .init(name: "x-error", value: "\(self.callbackScheme)://\(self.callbackHost)/error"),
            .init(name: "x-cancel", value: "\(self.callbackScheme)://\(self.callbackHost)/cancel"),
        ]
        return components.url
    }

    /// The outcome Shortcuts reported on the way back, if `url` is one of ours.
    static func callbackOutcome(_ url: URL) -> String? {
        guard url.scheme == self.callbackScheme, url.host == self.callbackHost else { return nil }
        let outcome = url.lastPathComponent
        return ["success", "error", "cancel"].contains(outcome) ? outcome : nil
    }

    private static func parameters(from paramsJSON: String?) -> Parameters? {
        guard let paramsJSON, paramsJSON.utf8.count <= 16_384,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              Set(object.keys) == ["recipient", "body"],
              let recipient = (object["recipient"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !recipient.isEmpty, recipient.count <= 256,
              let body = object["body"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 4_000
        else { return nil }
        return Parameters(recipient: recipient, body: body)
    }
}
