import AppIntents
import Foundation
import OSLog
import OperatorCore
import UserNotifications

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
    /// The shared shortcut names its action by bundle id, so it only finds
    /// Operator in the build it was made with. Any other build (a personal
    /// team's phone build has its own id) gets "an action could not be
    /// found", and the person has to make the shortcut by hand instead.
    static let sharedShortcutBundleID = "app.operator.ios"
    static var installURL: URL? {
        Bundle.main.bundleIdentifier == self.sharedShortcutBundleID
            ? URL(string: "https://www.icloud.com/shortcuts/786adfe7e3d440ef93f1b9652dcf4bcc")
            : nil
    }
    static let buildByHandSteps = """
        This copy of Operator has no install link. In Shortcuts tap +, then Automation, then Message, and set "Message contains" to one space. Add Operator's "Record incoming message" with Message and the Message's Sender. Enter the shortcut's name below.
        """
    /// Actual title served by installURL; update together when re-sharing.
    static let installedShortcutName = "Automation 6A0C5F28-28AA-4920-88F5-9ADCE0CFEDC8"

    static func automationPrompt(shortcutName: String) -> String {
        """
        Create an automation that runs immediately when I receive a message from any sender. Set “Message contains” to exactly one space character (U+0020), not the word “space” and not an empty field.

        Use Apple’s built-in Run Shortcut action to run my existing shortcut named “\(shortcutName)”. Pass Shortcut Input into that action, preserving the received message’s text and sender. Do not recreate the shortcut or add Operator actions directly. Run without confirmation whenever supported.
        """
    }

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
        if self.text.trimmingCharacters(in: .whitespacesAndNewlines) == ShortcutCheck.recordMarker {
            // A test run from Permissions: proof the shortcut is installed
            // and reaches Operator. Nothing is filed.
            UserDefaultsShortcutCheckStore().noteRecordActionRan(at: Date())
            logger.info("[shortcut-check] record action ran for a check")
            return .result()
        }
        let recorded = IncomingMessageStore.standard().record(sender: self.sender ?? "", text: self.text)
        if let recorded {
            do {
                let changed = try MessageConversationStore.standard().receive(.init(id: recorded.id, sender: recorded.sender, text: recorded.text, receivedAt: recorded.receivedAt))
                for id in changed {
                    let content = UNMutableNotificationContent()
                    content.title = "Conversation reply received"
                    content.body = "Open Operator to review the reply and continue your conversation task."
                    content.sound = .default
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "conversation-" + id, content: content, trigger: nil))
                }
            } catch { logger.error("[incoming-messages] conversation capture failed") }
        }
        logger.info("[incoming-messages] intent recorded=\(recorded != nil) characters=\(self.text.count)")
        return .result()
    }
}
