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
///
/// A group text is the same call with `recipients` instead of `recipient`:
/// `to` is then a list, which Send Message fans out to, and iMessage delivers
/// it into the thread that has exactly those people. There is no way to name
/// a group chat from outside Messages.
@MainActor
final class ForegroundMessageSendService: GatewayNodeCommandHandler {
    static let shortcutName = "OperatorSendMessage"
    static let callbackScheme = "app.operator.ios"
    static let callbackHost = "shortcut"

    /// The shortcut, shared from the Shortcuts app as an iCloud link. Opening
    /// the link itself is the install: iOS routes icloud.com/shortcuts into
    /// Shortcuts' preview, which has one Add Shortcut button. Everything else
    /// was tried and refused on iOS 18 and 26: unsigned files (since iOS 15),
    /// a signed file on any other https host ("The shortcut URL provided was
    /// invalid"), and shortcuts://import-shortcut pointed at this very link
    /// ("The file isn't in the correct format"). The file the link serves is
    /// checked in under Resources/shortcuts; sharing it again renews the link.
    static let installURL = URL(string: "https://www.icloud.com/shortcuts/cfc6a751e7f44cdc8f93a0da747e46f8")!

    static let groupLimit = ForegroundMessageDispatchService.groupLimit

    private struct Parameters {
        let recipients: [String]
        let body: String
    }

    private let store: IncomingMessageStore
    private let coordinator: ShortcutSendCoordinator
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let writeMode: @MainActor () -> MessageWriteMode
    private let customPrompt: CustomMessagePrompt?
    private let logger = Logger(subsystem: "app.operator.ios", category: "message-send")

    init(
        store: IncomingMessageStore = .standard(),
        coordinator: ShortcutSendCoordinator,
        isAppActive: @escaping @MainActor @Sendable () -> Bool,
        writeMode: @escaping @MainActor () -> MessageWriteMode = { .auto },
        customPrompt: CustomMessagePrompt? = nil)
    {
        self.store = store
        self.coordinator = coordinator
        self.isAppActive = isAppActive
        self.writeMode = writeMode
        self.customPrompt = customPrompt
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult {
        guard command == GatewayNativeNodeSurface.messageSendCommand else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let parameters = Self.parameters(from: paramsJSON) else {
            self.logger.info("[message-send] rejected invalid request shape")
            return .failure(code: "INVALID_REQUEST", message: "sms.send requires a nonempty recipient (or 2 to \(Self.groupLimit) recipients) and a nonempty body")
        }
        guard self.isAppActive() else {
            self.logger.info("[message-send] rejected while app inactive")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to send a message")
        }
        // Custom message: the person writes it. The model's body is dropped.
        var body = parameters.body
        var writtenByPerson = false
        if self.writeMode() == .custom, let customPrompt = self.customPrompt {
            guard let words = await customPrompt.write(to: parameters.recipients) else {
                return .success(payloadJSON: """
                {"handedToShortcut":false,"sent":false,"outcome":"declined","deliveryVerified":false,"nextStep":"The person writes their own texts and chose not to send this one. Nothing was sent. Do not try again unless they ask."}
                """)
            }
            body = words
            writtenByPerson = true
        }
        guard let url = Self.shortcutURL(recipients: parameters.recipients, body: body) else {
            return .failure(code: "INVALID_REQUEST", message: "The message could not be encoded for the shortcut")
        }
        self.logger.info("[message-send] handing to shortcut recipients=\(parameters.recipients.count) body_bytes=\(body.utf8.count) writtenByPerson=\(writtenByPerson)")
        // Waits for the shortcut to come back, so the model can continue after
        // the send. The process is kept alive across the hop; see the coordinator.
        let completion = await self.coordinator.send(url)
        switch completion.outcome {
        case .couldNotOpen:
            self.logger.info("[message-send] shortcut could not be opened")
            return .failure(
                code: "SHORTCUT_UNAVAILABLE",
                message: "The \"\(Self.shortcutName)\" shortcut could not be opened. The person has to create it once in the Shortcuts app; the steps are on Operator's Permissions page under \"\(ConnectorCatalog.descriptor(.messagesAutosend).title)\". Nothing was sent.")
        case .success:
            self.store.record(sender: parameters.recipients.joined(separator: ", "), text: body, direction: .sent)
            if writtenByPerson {
                return .success(payloadJSON: """
                {"handedToShortcut":true,"sent":true,"outcome":"success","writtenByPerson":true\(Self.jsonField("body", body)),"deliveryVerified":false,"nextStep":"The person wrote this message themselves and it was handed to Messages. Your draft was not used. Say it was sent; do not say it was delivered."}
                """)
            }
            return .success(payloadJSON: """
            {"handedToShortcut":true,"sent":true,"outcome":"success","deliveryVerified":false,"nextStep":"The shortcut ran and handed the message to Messages without asking. Say it was sent; do not say it was delivered, because delivery is not reported. You may continue with anything else the person asked."}
            """)
        case .error:
            let detail = Self.errorPayloadField(completion.message)
            return .success(payloadJSON: """
            {"handedToShortcut":true,"sent":false,"outcome":"error"\(detail),"deliveryVerified":false,"nextStep":"The send shortcut reported an error, so nothing was sent. Tell the person plainly what the error says; do not retry on your own."}
            """)
        case .cancel:
            return .success(payloadJSON: """
            {"handedToShortcut":true,"sent":false,"outcome":"cancel","deliveryVerified":false,"nextStep":"The send was cancelled, so nothing was sent. Tell the person."}
            """)
        case .timedOut:
            return .success(payloadJSON: """
            {"handedToShortcut":true,"sent":false,"outcome":"unknown","deliveryVerified":false,"nextStep":"The shortcut did not report back, so whether it sent is not known. Say you cannot confirm it; do not resend, which could send it twice."}
            """)
        }
    }

    /// shortcuts://x-callback-url/run-shortcut, with the message as a JSON
    /// text input and Operator's own scheme as the return address. One
    /// recipient is sent as a string, exactly as the shortcut was first proven
    /// with; a group is sent as a list.
    static func shortcutURL(recipients: [String], body: String) -> URL? {
        let to: Any = recipients.count == 1 ? recipients[0] : recipients
        guard let input = try? JSONSerialization.data(withJSONObject: ["to": to, "body": body], options: [.sortedKeys]),
              let text = String(data: input, encoding: .utf8)
        else { return nil }
        return self.runURL(shortcutName: self.shortcutName, text: text)
    }

    /// Runs the named shortcut with `text` as its input and Operator's own
    /// scheme as the return address.
    static func runURL(shortcutName: String, text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            .init(name: "name", value: shortcutName),
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

    /// The shortcut's own error text as a JSON field, bounded and escaped, or
    /// empty when it gave none.
    static func errorPayloadField(_ message: String?) -> String {
        guard let message, !message.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["shortcutError": String(message.prefix(300))]),
              let object = String(data: data, encoding: .utf8), object.hasPrefix("{"), object.hasSuffix("}")
        else { return "" }
        return "," + object.dropFirst().dropLast()
    }

    /// `,"name":"value"` with the value escaped, or empty if it cannot be.
    static func jsonField(_ name: String, _ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [name: value]),
              let object = String(data: data, encoding: .utf8), object.hasPrefix("{"), object.hasSuffix("}")
        else { return "" }
        return "," + object.dropFirst().dropLast()
    }

    /// The outcome and any error message from a return to Operator's scheme.
    static func callbackDetail(_ url: URL) -> (outcome: String, message: String?)? {
        guard let outcome = self.callbackOutcome(url) else { return nil }
        let message = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "errorMessage" }?.value
        return (outcome, message)
    }

    private static func parameters(from paramsJSON: String?) -> Parameters? {
        guard let paramsJSON, paramsJSON.utf8.count <= 16_384,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              let body = object["body"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 4_000
        else { return nil }
        let raw: [String]
        switch Set(object.keys) {
        case ["recipient", "body"]:
            guard let one = object["recipient"] as? String else { return nil }
            raw = [one]
        case ["recipients", "body"]:
            guard let several = object["recipients"] as? [String], (2...Self.groupLimit).contains(several.count) else { return nil }
            raw = several
        default:
            return nil
        }
        let recipients = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard recipients.allSatisfy({ !$0.isEmpty && $0.count <= 256 }),
              Set(recipients.map { $0.lowercased() }).count == recipients.count
        else { return nil }
        return Parameters(recipients: recipients, body: body)
    }
}
