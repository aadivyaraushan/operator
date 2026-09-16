import Contacts
import Foundation
import OperatorCore
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// Contacts is a lookup, never a listing.
//
// The whole value of this connector is turning "text Mom" into a handle
// sms.compose and whatsapp.compose can actually use. That job needs a name
// in and at most a handful of matches out. It never needs the address book,
// so there is no way to ask for it: a query is required, it must be
// non-empty, and there is no verb here that enumerates.
//
// That is a deliberate ceiling rather than an unfinished one. An agent that
// can page through every contact has copied the owner's social graph into a
// transcript, and no amount of good behaviour afterwards takes it back.

enum ContactsAccess: Equatable, Sendable {
    case notDetermined
    /// iOS 18 lets the owner grant a chosen subset. Matches inside that
    /// subset are returned normally; the ones outside it are indistinguishable
    /// from contacts that do not exist, which is the point of the setting.
    case limited
    case full
    case denied
}

struct ContactMatch: Sendable, Equatable {
    let displayName: String
    let phoneNumbers: [String]
    let emailAddresses: [String]
}

/// A contact to add: a name and at least one way to reach them. No notes
/// (a separate entitlement), no photos, no other fields.
struct ContactDraft: Codable, Equatable, Sendable {
    let givenName: String
    let familyName: String
    let phoneNumbers: [String]
    let emailAddresses: [String]

    var displayName: String { [self.givenName, self.familyName].filter { !$0.isEmpty }.joined(separator: " ") }
}

enum ContactDirectoryError: Error, Equatable, Sendable {
    case saveFailed
}

@MainActor
protocol ContactDirectory: AnyObject, Sendable {
    var access: ContactsAccess { get }
    func requestAccess() async -> Bool
    func search(query: String, limit: Int) async -> [ContactMatch]
    /// The contact already holding this number or address, if any.
    func existing(phoneNumber: String) async -> ContactMatch?
    func existing(emailAddress: String) async -> ContactMatch?
    /// Adds the contact and returns the display name as saved.
    func create(_ draft: ContactDraft) async throws -> String
}

@MainActor
final class ForegroundContactsService: GatewayNodeCommandHandler {
    static let maximumLimit = 10
    static let defaultLimit = 5
    static let maximumQueryLength = 100
    /// Handles per contact. Someone with nine numbers has one useful number
    /// and eight the agent should not be guessing between.
    static let maximumHandlesPerContact = 5

    private struct Payload: Encodable {
        struct Match: Encodable {
            let name: String
            let phones: [String]
            let emails: [String]
        }

        let matches: [Match]
        let partialAccess: Bool
    }

    private let directory: any ContactDirectory
    private let isAppActive: @MainActor @Sendable () -> Bool
    /// Whether the permission prompt could be shown right now. A lookup can
    /// run while a reply is kept alive in the background; a prompt cannot.
    private let canPrompt: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-contacts")

    init(
        directory: any ContactDirectory,
        isAppActive: @escaping @MainActor @Sendable () -> Bool,
        canPrompt: (@MainActor @Sendable () -> Bool)? = nil)
    {
        self.directory = directory
        self.isAppActive = isAppActive
        self.canPrompt = canPrompt ?? isAppActive
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "contacts.search" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let request = Self.request(from: paramsJSON) else {
            self.logger.info("[contacts] refused branch=invalid_params")
            return .failure(
                code: "INVALID_REQUEST",
                message: "contacts.search requires a nonempty query and an optional limit between 1 and \(Self.maximumLimit)")
        }
        guard self.isAppActive() else {
            self.logger.info("[contacts] refused branch=app_not_active")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to look up a contact")
        }
        // One deadline covers the permission prompt and the lookup together.
        let deadline = Date().addingTimeInterval(Double(GatewayDeadline.bounded(timeoutMilliseconds)) / 1_000)
        if self.directory.access == .denied {
            self.logger.info("[contacts] refused branch=permission_denied")
            return .failure(code: "PERMISSION_DENIED", message: "Contacts permission was denied")
        }
        if self.directory.access == .notDetermined {
            guard self.canPrompt() else {
                self.logger.info("[contacts] refused branch=cannot_prompt")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to allow Contacts access")
            }
            guard let granted = await GatewayDeadline.run(
                milliseconds: Int(deadline.timeIntervalSinceNow * 1_000),
                { [directory] in await directory.requestAccess() })
            else {
                self.logger.info("[contacts] refused branch=permission_timeout")
                return .failure(code: "TIMEOUT", message: "Contacts permission was not answered in time")
            }
            guard self.isAppActive() else {
                self.logger.info("[contacts] refused branch=app_left_during_permission")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to look up a contact")
            }
            guard granted else {
                self.logger.info("[contacts] refused branch=permission_request_denied")
                return .failure(code: "PERMISSION_DENIED", message: "Contacts permission was denied")
            }
        }

        let partial = self.directory.access == .limited
        guard let found = await GatewayDeadline.run(
            milliseconds: Int(deadline.timeIntervalSinceNow * 1_000),
            { [directory] in await directory.search(query: request.query, limit: request.limit) })
        else {
            self.logger.info("[contacts] refused branch=lookup_timeout")
            return .failure(code: "TIMEOUT", message: "Looking up that contact took too long")
        }
        let matches = found
            .prefix(request.limit)
            .map { match in
                Payload.Match(
                    name: match.displayName,
                    phones: Array(match.phoneNumbers.prefix(Self.maximumHandlesPerContact)),
                    emails: Array(match.emailAddresses.prefix(Self.maximumHandlesPerContact)))
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(matches: Array(matches), partialAccess: partial)),
              let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[contacts] failed branch=encode count=\(matches.count)")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not look up that contact")
        }
        // The query is not logged. A name being searched for is the content
        // of the request, not its shape.
        self.logger.info("[contacts] returned count=\(matches.count) partial=\(partial)")
        return .success(payloadJSON: payloadJSON)
    }

    struct Request: Equatable, Sendable {
        let query: String
        let limit: Int
    }

    static func request(from paramsJSON: String?) -> Request? {
        guard let paramsJSON, paramsJSON.utf8.count <= 4096,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["query", "limit"]),
              let rawQuery = object["query"] as? String
        else { return nil }

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= Self.maximumQueryLength else { return nil }

        guard let rawLimit = object["limit"] else { return Request(query: query, limit: Self.defaultLimit) }
        guard let limit = JSONNumber.integer(rawLimit, in: 1 ... Self.maximumLimit) else { return nil }
        return Request(query: query, limit: limit)
    }
}

@MainActor
final class SystemContactDirectory: ContactDirectory {
    private let store = CNContactStore()

    var access: ContactsAccess {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .full }
        if status == .notDetermined { return .notDetermined }
        // Partial access is an iOS-only status; the macOS SDK the fixture
        // suites build against does not define it.
        #if canImport(UIKit)
        if #available(iOS 18.0, *), status == .limited { return .limited }
        #endif
        return .denied
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            // Called back off the main actor; see the note in
            // ForegroundRemindersService for why this must be @Sendable.
            self.store.requestAccess(for: .contacts) { @Sendable granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static let keys: [any CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactPhoneNumbersKey as any CNKeyDescriptor,
        CNContactEmailAddressesKey as any CNKeyDescriptor,
    ]

    func search(query: String, limit: Int) async -> [ContactMatch] {
        let predicate = CNContact.predicateForContacts(matchingName: query)
        return self.matches(predicate).prefix(limit).map { $0 }
    }

    func existing(phoneNumber: String) async -> ContactMatch? {
        self.matches(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phoneNumber))).first
    }

    func existing(emailAddress: String) async -> ContactMatch? {
        self.matches(CNContact.predicateForContacts(matchingEmailAddress: emailAddress)).first
    }

    func create(_ draft: ContactDraft) async throws -> String {
        let contact = CNMutableContact()
        contact.givenName = draft.givenName
        contact.familyName = draft.familyName
        contact.phoneNumbers = draft.phoneNumbers.map {
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
        }
        contact.emailAddresses = draft.emailAddresses.map {
            CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try self.store.execute(request)
        } catch {
            throw ContactDirectoryError.saveFailed
        }
        return CNContactFormatter.string(from: contact, style: .fullName) ?? draft.displayName
    }

    private func matches(_ predicate: NSPredicate) -> [ContactMatch] {
        let contacts = (try? self.store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)) ?? []
        return contacts.map { contact in
            ContactMatch(
                displayName: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
                emailAddresses: contact.emailAddresses.map { $0.value as String })
        }
    }
}

#if canImport(UIKit)
extension ForegroundContactsService {
    convenience init() {
        self.init(
            directory: SystemContactDirectory(),
            isAppActive: { UIApplication.shared.applicationState == .active })
    }
}
#endif
