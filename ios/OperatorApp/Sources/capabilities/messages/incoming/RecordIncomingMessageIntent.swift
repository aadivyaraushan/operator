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
    /// A shortcut shared from the Shortcuts app, and the name it installs under.
    struct SharedShortcut: Equatable {
        let installURL: URL
        let name: String
    }

    /// A shared shortcut names its action by app id and team, so it only
    /// finds Operator in the build it was shared from; any other build gets
    /// "an action could not be found". Each build therefore has its own link.
    /// On iOS 27 the shortcut can carry its "When I receive a message"
    /// trigger, which survives sharing and arrives switched off.
    private static let sharedShortcuts: [String: SharedShortcut] = [
        // Shared 2026-09-16 from an automation, hence the name. No trigger
        // inside; re-share from the final app id before release.
        "app.operator.ios": SharedShortcut(
            installURL: URL(string: "https://www.icloud.com/shortcuts/786adfe7e3d440ef93f1b9652dcf4bcc")!,
            name: "Automation 6A0C5F28-28AA-4920-88F5-9ADCE0CFEDC8"),
        // The owner's phone build (personal team D847CBTR4K), shared
        // 2026-09-19. A message trigger must have a filter and only
        // "contains" exists, so it carries eleven triggers joined by "or"
        // (a space and ten common letters) to catch nearly every text.
        "app.operator.d847cbtr4k.ios": SharedShortcut(
            installURL: URL(string: "https://www.icloud.com/shortcuts/c8eafd8c7b924caa90aa086ada267dda")!,
            name: "Operator Read Messages"),
    ]

    static func sharedShortcut(forBundleID bundleID: String?) -> SharedShortcut? {
        bundleID.flatMap { self.sharedShortcuts[$0] }
    }

    static var installURL: URL? { self.sharedShortcut(forBundleID: Bundle.main.bundleIdentifier)?.installURL }
    static let buildByHandSteps = """
        This copy of Operator has no install link. In Shortcuts tap +, then Automation, then Message, and set "Message contains" to one space. Add Operator's "Record incoming message" with Message and the Message's Sender. Enter the shortcut's name below.
        """
    /// The name the installed shortcut has in Shortcuts, used to run it.
    static var installedShortcutName: String {
        self.sharedShortcut(forBundleID: Bundle.main.bundleIdentifier)?.name ?? self.shortcutName
    }

    /// A saved name that is only an old default (another build's shortcut, or
    /// the pre-link name) points at nothing on this phone, so it is dropped
    /// and the build's own default applies. A name the person chose is kept.
    static func savedNameToKeep(_ saved: String?, bundleID: String?) -> String? {
        guard let name = saved?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let own = self.sharedShortcut(forBundleID: bundleID)?.name
        let oldDefaults = Set(self.sharedShortcuts.values.map(\.name) + [self.shortcutName]).subtracting([own].compactMap { $0 })
        return oldDefaults.contains(name) ? nil : name
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Record \(\.$text) from \(\.$sender)")
    }

    /// Connected to the automation's input by Shortcuts itself when this is
    /// the first action, so the received message needs no wiring by hand.
    @Parameter(title: "Message", description: "The received message's text. Filled from the automation's Shortcut Input.", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String?

    @Parameter(title: "Sender", description: "Who sent it. Pass the Shortcut Input's Sender.")
    var sender: String?

    func perform() async throws -> some IntentResult {
        let logger = Logger(subsystem: "app.operator.ios", category: "incoming-messages")
        guard let text = self.text, !ShortcutCheck.isCheckRun(text: text) else {
            // A test run from Permissions: proof the shortcut is installed
            // and reaches Operator. Nothing is filed.
            UserDefaultsShortcutCheckStore().noteRecordActionRan(at: Date())
            logger.info("[shortcut-check] record action ran for a check")
            return .result()
        }
        let recorded = IncomingMessageStore.standard().record(sender: self.sender ?? "", text: text)
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
        logger.info("[incoming-messages] intent recorded=\(recorded != nil) characters=\(text.count)")
        return .result()
    }
}
