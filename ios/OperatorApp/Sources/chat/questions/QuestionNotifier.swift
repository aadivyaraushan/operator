#if canImport(UserNotifications)
import Foundation
import OperatorCore
import OSLog
import UserNotifications

/// The model's question as a notification, for a question asked while a
/// reply is being kept alive off screen. A single-choice question's options
/// are the notification's buttons; a free-text question gets a text field;
/// anything else (several questions, multi-select) says to open Operator,
/// where the card is waiting. Answers come back through
/// `QuestionNotificationResponder`.
///
/// Notification actions are fixed per category, and the options differ per
/// question, so each question registers its own category before posting.
@MainActor
final class QuestionNotifier {
    nonisolated static let categoryPrefix = "question-"
    nonisolated static let optionActionPrefix = "option-"
    nonisolated static let typedAction = "typed"
    nonisolated static let skipAction = "skip"
    nonisolated static let recordIDKey = "questionRecordID"
    nonisolated static let questionIDKey = "questionID"
    nonisolated static let optionLabelsKey = "optionLabels"
    private static let requestPrefix = "question-"
    private static let thread = "questions"
    /// iOS shows at most four actions; a fifth is never reachable.
    nonisolated private static let actionLimit = 4
    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "app.operator.ios", category: "question-notifier")

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    /// What a question notification carries, so the answer can be built
    /// from the response alone after the process was relaunched.
    struct Reference: Equatable, Sendable {
        let recordID: String
        let questionID: String
        let optionLabels: [String]
    }

    nonisolated static func reference(in response: UNNotificationResponse) -> Reference? {
        let content = response.notification.request.content
        guard content.categoryIdentifier.hasPrefix(Self.categoryPrefix),
              let recordID = content.userInfo[Self.recordIDKey] as? String,
              let questionID = content.userInfo[Self.questionIDKey] as? String
        else { return nil }
        return Reference(
            recordID: recordID, questionID: questionID,
            optionLabels: content.userInfo[Self.optionLabelsKey] as? [String] ?? [])
    }

    /// The answer a response stands for, or nil when the person only opened
    /// or dismissed the notification. Empty typed text is no answer.
    nonisolated static func answer(in response: UNNotificationResponse) -> (reference: Reference, values: [String])? {
        guard let reference = Self.reference(in: response) else { return nil }
        let action = response.actionIdentifier
        if action.hasPrefix(Self.optionActionPrefix),
           let index = Int(action.dropFirst(Self.optionActionPrefix.count)),
           reference.optionLabels.indices.contains(index)
        {
            return (reference, [reference.optionLabels[index]])
        }
        if action == Self.typedAction, let typed = (response as? UNTextInputNotificationResponse)?.userText {
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (reference, [text])
        }
        return nil
    }

    nonisolated static func isSkip(_ response: UNNotificationResponse) -> Bool {
        Self.reference(in: response) != nil && response.actionIdentifier == Self.skipAction
    }

    /// The actions a record's notification offers, and whether they can
    /// answer it. Pure, so the shape is testable without the center.
    nonisolated static func actions(for record: GatewayQuestionRecord) -> [UNNotificationAction] {
        guard record.questions.count == 1, let question = record.questions.first, !question.multiSelect else { return [] }
        var actions: [UNNotificationAction] = []
        for (index, option) in question.options.prefix(Self.actionLimit).enumerated() {
            actions.append(UNNotificationAction(identifier: Self.optionActionPrefix + String(index), title: option.label, options: []))
        }
        if question.acceptsFreeText, actions.count < Self.actionLimit {
            actions.append(UNTextInputNotificationAction(
                identifier: Self.typedAction, title: question.options.isEmpty ? "Answer" : "Type your own",
                options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        }
        if actions.count < Self.actionLimit {
            actions.append(UNNotificationAction(identifier: Self.skipAction, title: "Skip", options: [.destructive]))
        }
        return actions
    }

    func ask(_ record: GatewayQuestionRecord) {
        guard let question = record.questions.first else { return }
        let actions = Self.actions(for: record)
        let categoryID = Self.categoryPrefix + record.id
        let content = UNMutableNotificationContent()
        content.title = question.header.isEmpty ? "Operator has a question" : question.header
        content.body = Self.body(for: record, hasActions: !actions.isEmpty)
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.threadIdentifier = Self.thread
        content.userInfo = [
            Self.recordIDKey: record.id,
            Self.questionIDKey: question.questionId,
            Self.optionLabelsKey: question.options.prefix(Self.actionLimit).map(\.label),
        ]
        let request = UNNotificationRequest(identifier: Self.requestPrefix + record.id, content: content, trigger: nil)
        let category = UNNotificationCategory(identifier: categoryID, actions: actions, intentIdentifiers: [], options: [])
        // setNotificationCategories replaces the set: keep every other
        // category (the send confirmation, earlier questions) alongside.
        self.center.getNotificationCategories { [center, logger] existing in
            center.setNotificationCategories(existing.filter { $0.identifier != categoryID }.union([category]))
            center.add(request) { error in
                if let error {
                    logger.error("[question-notifier] post failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                } else {
                    logger.info("[question-notifier] posted id=\(record.id, privacy: .public) actions=\(actions.count)")
                }
            }
        }
    }

    /// The question was settled, by any means: the notification goes.
    func withdraw(id: String) {
        self.center.removeDeliveredNotifications(withIdentifiers: [Self.requestPrefix + id])
        self.center.removePendingNotificationRequests(withIdentifiers: [Self.requestPrefix + id])
        let categoryID = Self.categoryPrefix + id
        self.center.getNotificationCategories { [center] existing in
            center.setNotificationCategories(existing.filter { $0.identifier != categoryID })
        }
    }

    nonisolated static func body(for record: GatewayQuestionRecord, hasActions: Bool) -> String {
        let prompts = record.questions.map(\.question).joined(separator: " ")
        let flat = prompts.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let suffix = hasActions ? "" : " Open Operator to answer."
        let room = 240 - suffix.count
        let bounded = flat.count > room ? String(flat.prefix(room - 1)) + "…" : flat
        return bounded + suffix
    }
}

/// Handles a response to a question notification: a chosen option or typed
/// text is sent as the answer, Skip cancels, opening the app leaves the card
/// to it. The system keeps the process running until the handler returns,
/// which is what sending the answer needs.
final class QuestionNotificationResponder: NotificationResponseHandling, @unchecked Sendable {
    private let answer: @MainActor @Sendable (String, [String: [String]]) async -> Bool
    private let skip: @MainActor @Sendable (String) async -> Void
    private let logger = Logger(subsystem: "app.operator.ios", category: "question-notifier")

    init(
        answer: @escaping @MainActor @Sendable (String, [String: [String]]) async -> Bool,
        skip: @escaping @MainActor @Sendable (String) async -> Void)
    {
        self.answer = answer
        self.skip = skip
    }

    func handle(_ response: UNNotificationResponse) async -> Bool {
        guard let reference = QuestionNotifier.reference(in: response) else { return false }
        if let (_, values) = QuestionNotifier.answer(in: response) {
            self.logger.info("[question-notifier] answered id=\(reference.recordID, privacy: .public)")
            _ = await self.answer(reference.recordID, [reference.questionID: values])
        } else if QuestionNotifier.isSkip(response) {
            self.logger.info("[question-notifier] skipped id=\(reference.recordID, privacy: .public)")
            await self.skip(reference.recordID)
        } else {
            // Opened or dismissed: the card in the thread has it.
            self.logger.info("[question-notifier] opened id=\(reference.recordID, privacy: .public)")
        }
        return true
    }
}
#endif
