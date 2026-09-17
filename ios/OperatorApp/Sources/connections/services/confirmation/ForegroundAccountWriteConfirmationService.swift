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
private enum ConfirmationOutcome: Sendable { case finished(GatewayNodeCommandResult); case stillWaiting; case cancelled }

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
        let key = parsed.confirmation.fingerprint
        // A repeat of a request the owner has already answered gets that answer, once.
        if let settled = self.settled.removeValue(forKey: key) {
            logger.info("[account-write-confirmation] handed over operation=\(parsed.confirmation.operation.rawValue, privacy: .public) branch=settled-earlier")
            return settled
        }
        // A repeat while the card is still up joins it instead of replacing it.
        let work: Task<GatewayNodeCommandResult, Never>
        if let pending = self.pending[key] {
            logger.info("[account-write-confirmation] joined operation=\(parsed.confirmation.operation.rawValue, privacy: .public) branch=card-already-showing")
            work = pending
        } else {
            logger.info("[account-write-confirmation] presenting operation=\(parsed.confirmation.operation.rawValue, privacy: .public) wait_ms=\(milliseconds)")
            work = Task { @MainActor [weak self] in
                guard let self else { return .failure(code: "CANCELLED", message: "The account write was not performed") }
                return await self.confirmThenWrite(parsed)
            }
            self.pending[key] = work
        }
        switch await ConfirmationRace().run(work: work, milliseconds: max(1, milliseconds - 250)) {
        case let .finished(result):
            // This caller has the result, so nothing is kept for a repeat.
            self.pending[key] = nil; self.settled[key] = nil
            return result
        case .cancelled:
            logger.info("[account-write-confirmation] rejected operation=\(parsed.confirmation.operation.rawValue, privacy: .public) phase=confirmation reason=cancelled")
            self.pending[key] = nil; self.abandoned.insert(key)
            presenter.cancel(); return .failure(code: "CANCELLED", message: "The account write was cancelled")
        case .stillWaiting:
            // The gateway stops waiting here; the owner has not. The card stays
            // up, and whatever they decide is kept for a repeat of this request.
            logger.info("[account-write-confirmation] still waiting operation=\(parsed.confirmation.operation.rawValue, privacy: .public) branch=card-kept")
            Task { @MainActor [weak self] in
                let result = await work.value
                guard let self, self.pending[key] == work else { return }
                self.pending[key] = nil
                if self.abandoned.remove(key) == nil { self.settled[key] = result }
            }
            return .failure(code: "AWAITING_OWNER", message: Self.awaitingOwnerMessage)
        }
    }

    static let awaitingOwnerMessage = "The preview is still on the iPhone screen and nothing has been written yet. Tell the person it is waiting for their tap, and stop. When they say they tapped, send the exact same request once to get the result; do not change it and do not send it before then."

    private var pending: [String: Task<GatewayNodeCommandResult, Never>] = [:]
    private var settled: [String: GatewayNodeCommandResult] = [:]
    private var abandoned: Set<String> = []

    private func confirmThenWrite(_ parsed: Parsed) async -> GatewayNodeCommandResult {
        switch await presenter.confirm(parsed.confirmation) {
        case .denied:
            logger.info("[account-write-confirmation] rejected operation=\(parsed.confirmation.operation.rawValue, privacy: .public) phase=confirmation reason=owner-denied")
            return .failure(code: "OWNER_DENIED", message: "The account write was not performed")
        case let .confirmed(confirmed) where confirmed == parsed.confirmation: break
        case .confirmed:
            presenter.cancel(); return .failure(code: "CONFIRMATION_MISMATCH", message: "The account write was not performed")
        }
        guard isAppActive(), !self.abandoned.contains(parsed.confirmation.fingerprint) else { presenter.cancel(); return .failure(code: "CANCELLED", message: "The account write was not performed") }
        do {
            let receipt = try await writer.writeAfterOwnerConfirmation(parsed.request)
            logger.info("[account-write-confirmation] written operation=\(parsed.confirmation.operation.rawValue, privacy: .public)")
            return .success(payloadJSON: Self.receiptJSON(receipt, operation: parsed.confirmation.operation))
        } catch is CancellationError { return .failure(code: "CANCELLED", message: "The account write was cancelled") }
        catch let error as AccountWriteError { logger.error("[account-write-confirmation] write failed operation=\(parsed.confirmation.operation.rawValue, privacy: .public)"); return Self.result(for: error) }
        catch { return .failure(code: "ACCOUNT_WRITE_FAILED", message: "The account write could not complete") }
    }

    private struct Parsed: Sendable { let request: AccountWriteRequest; let confirmation: AccountWriteConfirmationRequest }

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
        case .googleSheetsUpdateCells, .googleSheetsAppendRows: required = ["operation", "fileID", "range", "rows"]; optional = []
        case .googleDocsAppendText: required = ["operation", "fileID", "text"]; optional = []
        case .googleDocsReplaceText, .googleSlidesReplaceText: required = ["operation", "fileID", "find", "replacement"]; optional = []
        case .googleSlidesAddSlide: required = ["operation", "fileID", "title", "body"]; optional = []
        case .googleDriveUpdateTextFile: required = ["operation", "fileID", "content"]; optional = []
        case .googleDriveRenameFile: required = ["operation", "fileID", "name"]; optional = []
        case .googleDriveMoveFile: required = ["operation", "fileID", "fromFolderID", "toFolderID"]; optional = []
        case .googleDriveCreateFile: required = ["operation", "name", "kind"]; optional = []
        case .googleTasksCreateTask: required = ["operation", "title"]; optional = ["list", "notes", "due"]
        case .googleTasksUpdateTask: required = ["operation", "taskID"]; optional = ["list", "title", "notes", "due", "completed"]
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
        case .googleSheetsUpdateCells, .googleSheetsAppendRows:
            // Cells are text only; a number or formula is written as its text.
            guard let id=string("fileID"), let range=string("range"), let rows=object["rows"] as? [[String]] else{return nil}
            let cells = GoogleSheetsCellsWrite(fileID:id,range:range,rows:rows)
            request = operation == .googleSheetsUpdateCells ? .googleSheetsUpdateCells(cells) : .googleSheetsAppendRows(cells)
        case .googleDocsAppendText: guard let id=string("fileID"),let text=string("text") else{return nil}; request = .googleDocsAppendText(.init(fileID:id,text:text))
        case .googleDocsReplaceText, .googleSlidesReplaceText:
            guard let id=string("fileID"),let find=string("find"),let replacement=string("replacement") else{return nil}
            let replace = GoogleReplaceTextWrite(fileID:id,find:find,replacement:replacement)
            request = operation == .googleDocsReplaceText ? .googleDocsReplaceText(replace) : .googleSlidesReplaceText(replace)
        case .googleSlidesAddSlide: guard let id=string("fileID"),let title=string("title"),let body=string("body") else{return nil}; request = .googleSlidesAddSlide(.init(fileID:id,title:title,body:body))
        case .googleDriveUpdateTextFile: guard let id=string("fileID"),let content=string("content") else{return nil}; request = .googleDriveUpdateTextFile(.init(fileID:id,content:content))
        case .googleDriveRenameFile: guard let id=string("fileID"),let name=string("name") else{return nil}; request = .googleDriveRenameFile(.init(fileID:id,name:name))
        case .googleDriveMoveFile: guard let id=string("fileID"),let from=string("fromFolderID"),let to=string("toFolderID") else{return nil}; request = .googleDriveMoveFile(.init(fileID:id,fromFolderID:from,toFolderID:to))
        case .googleDriveCreateFile: guard let name=string("name"),let kind=string("kind").flatMap(GoogleDriveCreateFileWrite.Kind.init(rawValue:)) else{return nil}; request = .googleDriveCreateFile(.init(name:name,kind:kind))
        case .googleTasksCreateTask:
            guard let title=string("title"),let list=optionalString("list"),let notes=optionalString("notes"),let due=optionalString("due") else{return nil}
            request = .googleTasksCreateTask(.init(list:list,title:title,notes:notes,due:due))
        case .googleTasksUpdateTask:
            guard let id=string("taskID"),let list=optionalString("list"),let title=optionalString("title"),let notes=optionalString("notes"),let due=optionalString("due") else{return nil}
            var completed: Bool?
            if let value = object["completed"], !(value is NSNull) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                completed = number.boolValue
            }
            request = .googleTasksUpdateTask(.init(list:list,taskID:id,title:title,notes:notes,due:due,completed:completed))
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
        case let .googleSheetsUpdateCells(v): "Overwrite cells \(v.range) in Google Sheet \(v.fileID)\n" + Self.table(v.rows)
        case let .googleSheetsAppendRows(v): "Add \(v.rows.count) row\(v.rows.count == 1 ? "" : "s") to \(v.range) in Google Sheet \(v.fileID)\n" + Self.table(v.rows)
        case let .googleDocsAppendText(v): "Add to the end of Google Doc \(v.fileID)\nText: \(v.text)"
        case let .googleDocsReplaceText(v): "In Google Doc \(v.fileID), replace every\n\(v.find)\nwith\n\(v.replacement)"
        case let .googleSlidesReplaceText(v): "In Google Slides deck \(v.fileID), replace every\n\(v.find)\nwith\n\(v.replacement)"
        case let .googleSlidesAddSlide(v): "Add a slide to the end of Google Slides deck \(v.fileID)\nTitle: \(v.title)\nBody: \(v.body)"
        case let .googleDriveUpdateTextFile(v): "Replace all the content of Drive file \(v.fileID)\nNew content: \(v.content)"
        case let .googleDriveRenameFile(v): "Rename Drive file \(v.fileID)\nNew name: \(v.name)"
        case let .googleDriveMoveFile(v): "Move Drive file \(v.fileID)\nFrom folder: \(v.fromFolderID)\nTo folder: \(v.toFolderID)"
        case let .googleDriveCreateFile(v): "New Google \(v.kind.rawValue) in Drive\nName: \(v.name)"
        case let .googleTasksCreateTask(v):
            "New Google task\nTitle: \(v.title)" + (v.notes.map { "\nNotes: \($0)" } ?? "") + (v.due.map { "\nDue: \($0)" } ?? "")
        case let .googleTasksUpdateTask(v):
            "Change Google task \(v.taskID)" + (v.title.map { "\nNew title: \($0)" } ?? "") + (v.notes.map { "\nNew notes: \($0)" } ?? "")
                + (v.due.map { "\nNew due day: \($0)" } ?? "") + (v.completed.map { $0 ? "\nMark it done" : "\nMark it not done" } ?? "")
        case let .outlookCreateDraft(v): "Outlook draft\nSubject: \(v.subject)\nBody: \(v.body)"
        case let .outlookSendMail(v): "Send email to \(v.to)\nSubject: \(v.subject)\nBody: \(v.body)"
        case let .slackPostMessage(v): "Slack channel \(v.channelID)\nMessage: \(v.text)"
        case let .spotifyStartPlayback(v): "Play Spotify track \(v.trackURI)\(v.deviceID.map { "\nDevice: \($0)" } ?? "")"
        }
    }

    /// Every row is shown: the owner is approving exactly these cells.
    private static func table(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
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
        case let .googleSheetCells(range, cells): "\"kind\":\"googleSheetCells\",\"range\":\(Self.jsonString(range)),\"cells\":\(cells)"
        case let .googleFileEdited(id, occurrences): "\"kind\":\"googleFileEdited\",\"id\":\"\(id)\"" + (occurrences.map { ",\"occurrencesChanged\":\($0)" } ?? "")
        case let .googleTask(id): "\"kind\":\"googleTask\",\"id\":\"\(id)\""
        case let .outlookDraft(id): "\"kind\":\"outlookDraft\",\"id\":\"\(id)\""
        case .outlookMailAccepted: "\"kind\":\"outlookMailAccepted\""
        case let .slackMessage(channelID, timestamp): "\"kind\":\"slackMessage\",\"channelID\":\"\(channelID)\",\"timestamp\":\"\(timestamp)\""
        case .spotifyPlaybackStarted: "\"kind\":\"spotifyPlaybackStarted\""
        }
        return "{\"ok\":true,\"operation\":\"\(operation.rawValue)\",\"receipt\":{\(detail)}}"
    }
    /// A sheet tab name can hold quotes and backslashes.
    private static func jsonString(_ value: String) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
    private static func result(for error: AccountWriteError) -> GatewayNodeCommandResult { switch error { case .notConnected: .failure(code:"NOT_CONNECTED",message:"Connect this account before writing"); case .permissionDenied: .failure(code:"PERMISSION_DENIED",message:"This account did not grant the needed write permission"); case .rateLimited: .failure(code:"RATE_LIMITED",message:"This account is temporarily rate limited"); case .outcomeUnknownNotSafeToRetry: .failure(code:"OUTCOME_UNKNOWN",message:"The account write outcome is unknown; do not retry"); default: .failure(code:"ACCOUNT_WRITE_FAILED",message:"The account write could not complete") } }
}

/// Waits for the card's task, the gateway's deadline, or the caller being
/// cancelled, whichever is first. It never touches the card itself.
@MainActor private final class ConfirmationRace {
    private var continuation: CheckedContinuation<ConfirmationOutcome, Never>?
    private var watcher: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    func run(work: Task<GatewayNodeCommandResult, Never>, milliseconds: Int) async -> ConfirmationOutcome {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfirmationOutcome, Never>) in
                self.continuation = continuation
                self.watcher = Task { [weak self] in let result = await work.value; self?.finish(.finished(result)) }
                self.timeout = Task { [weak self] in try? await Task.sleep(for: .milliseconds(milliseconds)); guard !Task.isCancelled else{return}; self?.finish(.stillWaiting) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.cancelled) } })
    }
    private func finish(_ value: ConfirmationOutcome) { guard let continuation else{return}; self.continuation=nil; timeout?.cancel(); continuation.resume(returning:value) }
}
