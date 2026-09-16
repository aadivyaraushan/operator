import Foundation
import OperatorCore
import OSLog

/// `messages.incoming`: the texts the owner received since the automation
/// was set up, newest first. Read-only, from the local feed; nothing here
/// touches Messages itself.
@MainActor
final class ForegroundIncomingMessagesService: GatewayNodeCommandHandler {
    static let command = "messages.incoming"
    static let defaultLimit = 25

    private let store: IncomingMessageStore
    private let logger = Logger(subsystem: "app.operator.ios", category: "incoming-messages")

    init(store: IncomingMessageStore) {
        self.store = store
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult {
        guard command == Self.command else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let parameters = Self.parameters(from: paramsJSON) else {
            return .failure(code: "INVALID_REQUEST", message: "messages.incoming takes optional sinceRFC3339 and limit (1 to 100) and nothing else")
        }
        let messages = self.store.messages(since: parameters.since, limit: parameters.limit)
        let total = self.store.count
        self.logger.info("[incoming-messages] read returned=\(messages.count) stored=\(total)")
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "messages": messages.map { message -> [String: Any] in
                ["id": message.id, "from": message.sender, "text": message.text, "receivedAt": formatter.string(from: message.receivedAt)]
            },
            "storedCount": total,
            "readAt": formatter.string(from: Date()),
            "nextStep": "These are texts received since the person set up the automation, newest first; nothing older, nothing they sent, and no read state. Report who said what and when. To reply, use the Messages send tools.",
        ]
        if total == 0 {
            payload["note"] = "No texts have been recorded. Either none arrived since setup, or the \"When I get a message\" automation is not set up yet: the steps are on Operator's Permissions page under Messages."
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 262_144 else {
            return .failure(code: "RESPONSE_TOO_LARGE", message: "Too many messages to return; ask for fewer with limit")
        }
        return .success(payloadJSON: String(decoding: data, as: UTF8.self))
    }

    private struct Parameters {
        let since: Date?
        let limit: Int
    }

    private static func parameters(from paramsJSON: String?) -> Parameters? {
        guard let paramsJSON, paramsJSON.utf8.count <= 4_096 else { return Parameters(since: nil, limit: Self.defaultLimit) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any],
              Set(object.keys).isSubset(of: ["sinceRFC3339", "limit"])
        else { return nil }
        var since: Date?
        if let raw = object["sinceRFC3339"], !(raw is NSNull) {
            guard let text = raw as? String, let date = Self.date(text) else { return nil }
            since = date
        }
        var limit = Self.defaultLimit
        if let raw = object["limit"], !(raw is NSNull) {
            guard let parsed = JSONNumber.integer(raw, in: 1...100) else { return nil }
            limit = parsed
        }
        return Parameters(since: since, limit: limit)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
