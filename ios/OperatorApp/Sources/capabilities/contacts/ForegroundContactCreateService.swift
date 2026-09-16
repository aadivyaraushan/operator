import Foundation
import OperatorCore
import OSLog

enum ContactCreateDecision: Sendable { case confirmed(ContactDraft); case denied }

/// Shows the owner exactly what would be saved and waits for a tap.
@MainActor
protocol ContactCreatePresenter: AnyObject, Sendable {
    func confirm(_ draft: ContactDraft) async -> ContactCreateDecision
    func cancel()
}

/// `contacts.create`: a new contact, after the owner has seen it and tapped
/// Save. It only ever adds: a number or address already in Contacts is
/// refused with the name it belongs to, so nothing existing is changed,
/// duplicated or overwritten.
@MainActor
final class ForegroundContactCreateService: GatewayNodeCommandHandler {
    static let command = "contacts.create"
    static let maximumHandles = 3
    static let maximumNameLength = 100
    static let maximumHandleLength = 100

    private enum Confirmation: Sendable { case decision(ContactCreateDecision); case timedOut }

    private let directory: any ContactDirectory
    private let presenter: any ContactCreatePresenter
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "contacts-create")

    init(directory: any ContactDirectory, presenter: any ContactCreatePresenter, isAppActive: @escaping @MainActor @Sendable () -> Bool) {
        self.directory = directory
        self.presenter = presenter
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        guard command == Self.command else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let draft = Self.draft(from: paramsJSON) else {
            self.logger.info("[contacts-create] refused branch=invalid_params")
            return .failure(code: "INVALID_REQUEST", message: "contacts.create requires name (1 to \(Self.maximumNameLength) characters) and at least one of phones or emails (up to \(Self.maximumHandles) each), and nothing else")
        }
        guard self.isAppActive() else {
            self.logger.info("[contacts-create] refused branch=app_not_active")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to save a contact")
        }
        let deadline = Date().addingTimeInterval(Double(GatewayDeadline.bounded(timeoutMilliseconds)) / 1_000)
        if self.directory.access == .denied {
            self.logger.info("[contacts-create] refused branch=permission_denied")
            return .failure(code: "PERMISSION_DENIED", message: "Contacts permission was denied")
        }
        if self.directory.access == .notDetermined {
            guard let granted = await GatewayDeadline.run(milliseconds: Int(deadline.timeIntervalSinceNow * 1_000), { [directory] in await directory.requestAccess() }) else {
                return .failure(code: "TIMEOUT", message: "Contacts permission was not answered in time")
            }
            guard self.isAppActive() else { return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to save a contact") }
            guard granted else {
                self.logger.info("[contacts-create] refused branch=permission_request_denied")
                return .failure(code: "PERMISSION_DENIED", message: "Contacts permission was denied")
            }
        }
        // Refused before the owner is asked: the number or address is
        // already someone's, and this command never edits anyone.
        for phone in draft.phoneNumbers {
            if let existing = await self.directory.existing(phoneNumber: phone) {
                self.logger.info("[contacts-create] refused branch=phone_exists")
                return .failure(code: "ALREADY_EXISTS", message: "\(phone) is already in Contacts as \(existing.displayName). Nothing was saved; contacts.create never changes an existing contact.")
            }
        }
        for email in draft.emailAddresses {
            if let existing = await self.directory.existing(emailAddress: email) {
                self.logger.info("[contacts-create] refused branch=email_exists")
                return .failure(code: "ALREADY_EXISTS", message: "\(email) is already in Contacts as \(existing.displayName). Nothing was saved; contacts.create never changes an existing contact.")
            }
        }
        let milliseconds = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
        self.logger.info("[contacts-create] awaiting-owner-confirmation phones=\(draft.phoneNumbers.count) emails=\(draft.emailAddresses.count)")
        switch await self.confirm(draft, milliseconds: milliseconds) {
        case .timedOut:
            self.logger.info("[contacts-create] refused branch=timeout")
            return .failure(code: "TIMEOUT", message: "The contact was not saved: no answer in time")
        case let .decision(.confirmed(confirmed)) where confirmed == draft:
            break
        case .decision(.confirmed):
            self.presenter.cancel()
            self.logger.error("[contacts-create] refused branch=confirmation_mismatch")
            return .failure(code: "CONFIRMATION_MISMATCH", message: "The contact was not saved")
        case .decision(.denied):
            self.logger.info("[contacts-create] refused branch=owner_denied")
            return .failure(code: "OWNER_DENIED", message: "The person chose not to save this contact")
        }
        guard self.isAppActive(), !Task.isCancelled else {
            self.presenter.cancel()
            return .failure(code: "APP_NOT_ACTIVE", message: "The contact was not saved")
        }
        do {
            let saved = try await self.directory.create(draft)
            self.logger.info("[contacts-create] completed")
            let payload: [String: Any] = ["saved": true, "name": saved, "phones": draft.phoneNumbers, "emails": draft.emailAddresses]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return .success(payloadJSON: String(decoding: data, as: UTF8.self))
        } catch {
            self.logger.error("[contacts-create] failed branch=save")
            return .failure(code: "SAVE_FAILED", message: "iOS did not save the contact")
        }
    }

    private func confirm(_ draft: ContactDraft, milliseconds: Int) async -> Confirmation {
        await withTaskGroup(of: Confirmation.self) { group in
            group.addTask { @MainActor @Sendable [presenter] in .decision(await presenter.confirm(draft)) }
            group.addTask { try? await Task.sleep(for: .milliseconds(milliseconds)); return .timedOut }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            if case .timedOut = first { self.presenter.cancel() }
            return first
        }
    }

    /// `name`, then `phones` and/or `emails`. The name's first word is the
    /// given name and the rest the family name, which is how Contacts sorts
    /// and shows it; "Villa" is a given name alone.
    static func draft(from paramsJSON: String?) -> ContactDraft? {
        guard let paramsJSON, paramsJSON.utf8.count <= 4_096,
              let object = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any],
              Set(object.keys).isSubset(of: ["name", "phones", "emails"]),
              let rawName = object["name"] as? String
        else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maximumNameLength, !name.contains("\n") else { return nil }
        func handles(_ key: String) -> [String]? {
            guard let raw = object[key], !(raw is NSNull) else { return [] }
            guard let list = raw as? [Any], list.count <= Self.maximumHandles else { return nil }
            var out: [String] = []
            for item in list {
                guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      text.count <= Self.maximumHandleLength, !text.contains("\n")
                else { return nil }
                if !out.contains(text) { out.append(text) }
            }
            return out
        }
        guard let phones = handles("phones"), let emails = handles("emails"), !(phones.isEmpty && emails.isEmpty) else { return nil }
        for email in emails where !email.contains("@") || email.contains(" ") { return nil }
        let parts = name.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let given = parts.first ?? name
        let family = parts.dropFirst().joined(separator: " ")
        return ContactDraft(givenName: given, familyName: family, phoneNumbers: phones, emailAddresses: emails)
    }
}
