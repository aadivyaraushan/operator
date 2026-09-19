import AppIntents

struct OperatorChatAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Operator"
    static let description = IntentDescription("Open your saved Operator conversation.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct OperatorChatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OperatorChatAppIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Open Operator",
            systemImageName: "message")
    }
}
