import Foundation
import OperatorCore
import OSLog

struct AccountWriteConfirmationRequest: Equatable, Sendable {
    let operation: AccountWriteOperation
    let preview: String
    fileprivate let fingerprint: String
}

enum AccountWriteDecision: Sendable {
    case confirmed(AccountWriteConfirmationRequest)
    case denied
}
private enum ConfirmationOutcome: Sendable { case decision(AccountWriteDecision); case timedOut; case cancelled }

@MainActor protocol AccountWriteConfirmationPresenting: AnyObject, Sendable {
    func confirm(_ request: AccountWriteConfirmationRequest) async -> AccountWriteDecision
    func cancel()
}

protocol AccountWriteExecuting: Sendable {
    func writeAfterOwnerConfirmation(_ input: AccountWriteRequest) async throws -> AccountWriteReceipt
}

extension DirectAccountWriter: AccountWriteExecuting {}

@MainActor final class ForegroundAccountWriteConfirmationService: GatewayNodeCommandHandler {
    private let writer: any AccountWriteExecuting
    private let presenter: any AccountWriteConfirmationPresenting
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "account-write-confirmation")

    init(writer: any AccountWriteExecuting, presenter: any AccountWriteConfirmationPresenting, isAppActive: @escaping @MainActor @Sendable () -> Bool) {
        self.writer = writer; self.presenter = presenter; self.isAppActive = isAppActive
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        guard command == "connections.write" else { return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)") }
        guard isAppActive() else { return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to confirm the account write") }
        guard let parsed = Self.parse(paramsJSON) else { return .failure(code: "INVALID_REQUEST", message: "Connection write parameters were invalid") }
        guard DirectAccountWriter.isValid(parsed.request) else { logger.info("[account-write-confirmation] rejected branch=typed-validation"); return .failure(code: "INVALID_REQUEST", message: "Connection write parameters were invalid") }
        let milliseconds = max(1, min(timeoutMilliseconds ?? 30_000, 30_000))
        let outcome = await ConfirmationRace().run(presenter: presenter, request: parsed.confirmation, milliseconds: max(1, milliseconds - 250))
        switch outcome {
        case .timedOut:
            logger.info("[account-write-confirmation] rejected operation=\(parsed.confirmation.operation.rawValue, privacy: .public) phase=confirmation reason=timeout")
            presenter.cancel(); return .failure(code: "TIMEOUT", message: "The account write preview expired")
        case .cancelled:
            logger.info("[account-write-confirmation] rejected operation=\(parsed.confirmation.operation.rawValue, privacy: .public) phase=confirmation reason=cancelled")
            presenter.cancel(); return .failure(code: "CANCELLED", message: "The account write was cancelled")
        case .decision(.denied):
            logger.info("[account-write-confirmation] rejected operation=\(parsed.confirmation.operation.rawValue, privacy: .public) phase=confirmation reason=owner-denied")
            presenter.cancel(); return .failure(code: "OWNER_DENIED", message: "The account write was not performed")
        case let .decision(.confirmed(confirmed)) where confirmed == parsed.confirmation: break
        case .decision(.confirmed):
            presenter.cancel(); return .failure(code: "CONFIRMATION_MISMATCH", message: "The account write was not performed")
        }
        guard isAppActive(), !Task.isCancelled else { presenter.cancel(); return .failure(code: "CANCELLED", message: "The account write was not performed") }
        do {
            let receipt = try await writer.writeAfterOwnerConfirmation(parsed.request)
            return .success(payloadJSON: Self.receiptJSON(receipt, operation: parsed.confirmation.operation))
        } catch is CancellationError { return .failure(code: "CANCELLED", message: "The account write was cancelled") }
        catch let error as AccountWriteError { return Self.result(for: error) }
        catch { return .failure(code: "ACCOUNT_WRITE_FAILED", message: "The account write could not complete") }
    }

    private struct Parsed { let request: AccountWriteRequest; let confirmation: AccountWriteConfirmationRequest }

    private static func parse(_ raw: String?) -> Parsed? {
        guard let raw, Data(raw.utf8).count <= 64_000, let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], let opText = object["operation"] as? String, let operation = AccountWriteOperation(rawValue: opText) else { return nil }
        // Every key must be known, every required key present. Optional keys
        // may be absent or null; a present key must still have the right type.
        let required: Set<String>
        let optional: Set<String>
        switch operation {
        case .googleCalendarCreateEvent: required = ["operation", "summary", "description", "startRFC3339", "endRFC3339"]; optional = ["attendees", "addMeetLink"]
        case .googleCalendarUpdateEvent: required = ["operation", "eventID"]; optional = ["summary", "description", "startRFC3339", "endRFC3339", "attendees", "addMeetLink"]
        case .googleDriveCreateTextFile: required = ["operation", "name", "content"]; optional = []
        case .outlookCreateDraft: required = ["operation", "subject", "body"]; optional = []
        case .outlookSendMail: required = ["operation", "to", "subject", "body"]; optional = []
        case .slackPostMessage: required = ["operation", "channelID", "text"]; optional = []
        case .spotifyStartPlayback: required = ["operation", "trackURI"]; optional = ["deviceID"]
        }
        let keys = Set(object.keys)
        guard keys.isSuperset(of: required), keys.isSubset(of: required.union(optional)) else { return nil }
        func string(_ key: String) -> String? { object[key] as? String }
        /// Outer nil: present with the wrong type, which rejects the request.
        /// Inner nil: absent or null, which leaves the field untouched.
        func optionalString(_ key: String) -> String?? {
            guard let value = object[key], !(value is NSNull) else { return .some(nil) }
            guard let text = value as? String else { return nil }
            return .some(text)
        }
        func optionalStrings(_ key: String) -> [String]?? {
            guard let value = object[key], !(value is NSNull) else { return .some(nil) }
            guard let list = value as? [String] else { return nil }
            return .some(list)
        }
        func optionalFlag(_ key: String) -> Bool? {
            guard let value = object[key], !(value is NSNull) else { return false }
            // JSONSerialization hands booleans back as NSNumber; a 0/1 would pass too, which is fine.
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        let request: AccountWriteRequest
        switch operation {
        case .googleCalendarCreateEvent:
            guard let a=string("summary"),let b=string("description"),let c=string("startRFC3339"),let d=string("endRFC3339"), let attendees=optionalStrings("attendees"), let meet=optionalFlag("addMeetLink") else{return nil}
            request = .googleCalendarCreateEvent(.init(summary:a,description:b,startRFC3339:c,endRFC3339:d,attendees:attendees ?? [],addMeetLink:meet))
        case .googleCalendarUpdateEvent:
            guard let id=string("eventID"), let summary=optionalString("summary"), let description=optionalString("description"),
                  let start=optionalString("startRFC3339"), let end=optionalString("endRFC3339"), let attendees=optionalStrings("attendees"), let meet=optionalFlag("addMeetLink") else{return nil}
            request = .googleCalendarUpdateEvent(.init(eventID:id,summary:summary,description:description,startRFC3339:start,endRFC3339:end,attendees:attendees,addMeetLink:meet))
        case .googleDriveCreateTextFile: guard let a=string("name"),let b=string("content") else{return nil}; request = .googleDriveCreateTextFile(.init(name:a,content:b))
        case .outlookCreateDraft: guard let a=string("subject"),let b=string("body") else{return nil}; request = .outlookCreateDraft(.init(subject:a,body:b))
        case .outlookSendMail: guard let a=string("to"),let b=string("subject"),let c=string("body") else{return nil}; request = .outlookSendMail(.init(to:a,subject:b,body:c))
        case .slackPostMessage: guard let a=string("channelID"),let b=string("text") else{return nil}; request = .slackPostMessage(.init(channelID:a,text:b))
        case .spotifyStartPlayback: guard let a=string("trackURI"), let deviceID=optionalString("deviceID") else{return nil}; request = .spotifyStartPlayback(.init(trackURI:a,deviceID:deviceID))
        }
        let fingerprint = Self.fingerprint(request)
        return Parsed(request: request, confirmation: .init(operation: operation, preview: Self.preview(request), fingerprint: fingerprint))
    }

    private static func fingerprint(_ request: AccountWriteRequest) -> String { String(describing: request.operation) + "|" + preview(request) }
    private static func preview(_ request: AccountWriteRequest) -> String {
        switch request {
        case let .googleCalendarCreateEvent(v): "Calendar event\nSummary: \(v.summary)\nStarts: \(v.startRFC3339)\nEnds: \(v.endRFC3339)\nDescription: \(v.description)" + (v.attendees.isEmpty ? "" : "\nInvites sent to: \(v.attendees.joined(separator: ", "))") + (v.addMeetLink ? "\nGoogle Meet link: added" : "")
        case let .googleCalendarUpdateEvent(v): Self.updatePreview(v)
        case let .googleDriveCreateTextFile(v): "Drive file \(v.name)\nContent: \(v.content)"
        case let .outlookCreateDraft(v): "Outlook draft\nSubject: \(v.subject)\nBody: \(v.body)"
        case let .outlookSendMail(v): "Send email to \(v.to)\nSubject: \(v.subject)\nBody: \(v.body)"
        case let .slackPostMessage(v): "Slack channel \(v.channelID)\nMessage: \(v.text)"
        case let .spotifyStartPlayback(v): "Play Spotify track \(v.trackURI)\(v.deviceID.map { "\nDevice: \($0)" } ?? "")"
        }
    }

    /// Only what changes is shown, so an unchanged field is not mistaken for
    /// one being blanked.
    private static func updatePreview(_ v: GoogleCalendarUpdateEventWrite) -> String {
        var lines = ["Update calendar event \(v.eventID)"]
        if let summary = v.summary { lines.append("Summary: \(summary)") }
        if let start = v.startRFC3339 { lines.append("Starts: \(start)") }
        if let end = v.endRFC3339 { lines.append("Ends: \(end)") }
        if let description = v.description { lines.append("Description: \(description)") }
        if let attendees = v.attendees { lines.append("Guest list becomes: \(attendees.isEmpty ? "nobody" : attendees.joined(separator: ", "))") }
        if v.addMeetLink { lines.append("Google Meet link: added") }
        return lines.joined(separator: "\n")
    }

    private static func receiptJSON(_ receipt: AccountWriteReceipt, operation: AccountWriteOperation) -> String {
        let detail: String = switch receipt {
        case let .googleCalendarEvent(id, meetLink): "\"kind\":\"googleCalendarEvent\",\"id\":\"\(id)\"" + (meetLink.map { ",\"meetLink\":\"\($0)\"" } ?? "")
        case let .googleDriveFile(id): "\"kind\":\"googleDriveFile\",\"id\":\"\(id)\""
        case let .outlookDraft(id): "\"kind\":\"outlookDraft\",\"id\":\"\(id)\""
        case .outlookMailAccepted: "\"kind\":\"outlookMailAccepted\""
        case let .slackMessage(channelID, timestamp): "\"kind\":\"slackMessage\",\"channelID\":\"\(channelID)\",\"timestamp\":\"\(timestamp)\""
        case .spotifyPlaybackStarted: "\"kind\":\"spotifyPlaybackStarted\""
        }
        return "{\"ok\":true,\"operation\":\"\(operation.rawValue)\",\"receipt\":{\(detail)}}"
    }
    private static func result(for error: AccountWriteError) -> GatewayNodeCommandResult { switch error { case .notConnected: .failure(code:"NOT_CONNECTED",message:"Connect this account before writing"); case .permissionDenied: .failure(code:"PERMISSION_DENIED",message:"This account did not grant the needed write permission"); case .rateLimited: .failure(code:"RATE_LIMITED",message:"This account is temporarily rate limited"); case .outcomeUnknownNotSafeToRetry: .failure(code:"OUTCOME_UNKNOWN",message:"The account write outcome is unknown; do not retry"); default: .failure(code:"ACCOUNT_WRITE_FAILED",message:"The account write could not complete") } }
}

@MainActor private final class ConfirmationRace {
    private var continuation: CheckedContinuation<ConfirmationOutcome, Never>?
    private var confirmation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    func run(presenter: any AccountWriteConfirmationPresenting, request: AccountWriteConfirmationRequest, milliseconds: Int) async -> ConfirmationOutcome {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfirmationOutcome, Never>) in
                self.continuation = continuation
                self.confirmation = Task { [weak self] in self?.finish(.decision(await presenter.confirm(request))) }
                self.timeout = Task { [weak self] in try? await Task.sleep(for: .milliseconds(milliseconds)); guard !Task.isCancelled else{return}; self?.finish(.timedOut) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.cancelled) } })
    }
    private func finish(_ value: ConfirmationOutcome) { guard let continuation else{return}; self.continuation=nil; confirmation?.cancel(); timeout?.cancel(); continuation.resume(returning:value) }
}
