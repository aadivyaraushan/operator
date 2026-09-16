import AppIntents
import Foundation
import OSLog

/// What a Shortcuts "When I get a message" automation runs: it hands the
/// received text and sender here, and this files them for the
/// `messages.incoming` command. Runs in the background without opening the
/// app; the Node runtime is not started for it.
struct RecordIncomingMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Record incoming message"
    static let description = IntentDescription(
        "Files a text you received so Operator can tell you about it. Meant to be run by a \"When I get a message\" automation.")
    static let openAppWhenRun = false
    static var parameterSummary: some ParameterSummary {
        Summary("Record \(\.$text) from \(\.$sender)")
    }

    @Parameter(title: "Message", description: "The received message's text. Pass the automation's Shortcut Input.")
    var text: String

    @Parameter(title: "Sender", description: "Who sent it. Pass the Shortcut Input's Sender.")
    var sender: String?

    func perform() async throws -> some IntentResult {
        let logger = Logger(subsystem: "app.operator.ios", category: "incoming-messages")
        let recorded = IncomingMessageStore.standard().record(sender: self.sender ?? "", text: self.text)
        logger.info("[incoming-messages] intent recorded=\(recorded != nil) characters=\(self.text.count)")
        return .result()
    }
}
