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

    /// Opens Shortcuts on its new-automation picker (undocumented, works on
    /// iOS 18): from there it is Message, Run Immediately, Next, and the
    /// shortcut below. Apple gives no way to create the automation itself.
    static let createAutomationURL = URL(string: "shortcuts://create-automation")!
    /// The shortcut that carries the field wiring, shared from the Shortcuts
    /// app as an iCloud link like OperatorSendMessage's. Nil until the owner
    /// has built and shared it once; the Permissions page then offers it.
    static let shortcutName = "OperatorRecordMessage"
    static let installURL: URL? = nil
    static var parameterSummary: some ParameterSummary {
        Summary("Record \(\.$text) from \(\.$sender)")
    }

    /// Connected to the automation's input by Shortcuts itself when this is
    /// the first action, so the received message needs no wiring by hand.
    @Parameter(title: "Message", description: "The received message's text. Filled from the automation's Shortcut Input.", inputConnectionBehavior: .connectToPreviousIntentResult)
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
