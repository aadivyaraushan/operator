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
    /// The shortcut that carries the field wiring (Message from the input,
    /// Sender from the input's Sender), shared from the Shortcuts app as an
    /// iCloud link like OperatorSendMessage's; the signed file the link serves
    /// is checked in under Resources/shortcuts. Shared from the owner's
    /// automation on 2026-09-16, so Shortcuts shows it under the automation's
    /// own name, "Automation 6A0C5F28…", until it is re-shared renamed.
    static let shortcutName = "OperatorRecordMessage"
    static let installURL: URL? = URL(string: "https://www.icloud.com/shortcuts/786adfe7e3d440ef93f1b9652dcf4bcc")
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
