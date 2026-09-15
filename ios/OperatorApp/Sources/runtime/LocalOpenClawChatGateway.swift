import Foundation
import OperatorCore
import OSLog

struct LocalChatDeliveryTimingEvent: Equatable, Sendable {
    enum Phase: String, Sendable {
        case accepted
        case firstText = "first-text"
        case terminal
    }

    enum Outcome: String, Sendable {
        case reply
        case failed
        case stopped
        case error
    }

    let phase: Phase
    let elapsedMilliseconds: Double
    let outcome: Outcome?

    init(phase: Phase, elapsedMilliseconds: Double, outcome: Outcome? = nil) {
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
        self.outcome = outcome
    }
}

private struct LocalChatDeliveryTimer {
    let startedAtMilliseconds: Double
    private(set) var acceptedRecorded = false
    private(set) var firstTextRecorded = false
    private(set) var terminalRecorded = false

    init(startedAtMilliseconds: Double) {
        self.startedAtMilliseconds = startedAtMilliseconds
    }

    mutating func accepted(at now: Double) -> LocalChatDeliveryTimingEvent? {
        guard !self.acceptedRecorded else { return nil }
        self.acceptedRecorded = true
        return self.event(phase: .accepted, at: now)
    }

    mutating func firstText(in text: String, at now: Double) -> LocalChatDeliveryTimingEvent? {
        guard !self.firstTextRecorded,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.firstTextRecorded = true
        return self.event(phase: .firstText, at: now)
    }

    mutating func terminal(
        outcome: LocalChatDeliveryTimingEvent.Outcome,
        at now: Double) -> LocalChatDeliveryTimingEvent?
    {
        guard !self.terminalRecorded else { return nil }
        self.terminalRecorded = true
        return self.event(phase: .terminal, at: now, outcome: outcome)
    }

    private func event(
        phase: LocalChatDeliveryTimingEvent.Phase,
        at now: Double,
        outcome: LocalChatDeliveryTimingEvent.Outcome? = nil) -> LocalChatDeliveryTimingEvent
    {
        LocalChatDeliveryTimingEvent(
            phase: phase,
            elapsedMilliseconds: max(0, now - self.startedAtMilliseconds),
            outcome: outcome)
    }
}

private extension GatewayConversationEvent {
    var runID: String {
        switch self {
        case let .working(runID), let .stream(runID, _), let .reply(runID, _),
             let .failed(runID, _), let .stopped(runID):
            return runID
        }
    }
}

actor LocalOpenClawChatGateway: ChatGateway {
    private let connectionFactory: @Sendable () async throws -> OpenClawGatewayConnection
    private let monotonicMilliseconds: @Sendable () -> Double
    private let timingSink: (@Sendable (LocalChatDeliveryTimingEvent) -> Void)?
    private let logger = Logger(subsystem: "app.operator.ios", category: "local-gateway")
    private var connection: OpenClawGatewayConnection?
    private var activeRunID: String?
    private var approvalUpdate: (@Sendable (ChatApprovalUpdate) async -> Void)?
    private var isDelivering = false
    private var isActivating = false
    private var approvalRequestsInFlight = 0

    init(url: URL, vault: GatewayInstallationVault, appVersion: String, platform: String) {
        self.monotonicMilliseconds = Self.defaultMonotonicMilliseconds
        self.timingSink = nil
        self.connectionFactory = {
            let credentials = try await vault.loadOrCreate()
            return OpenClawGatewayConnection(
                transport: URLSessionGatewayTransport(url: url, timeout: 30),
                token: credentials.gatewayToken,
                identity: credentials.identity,
                metadata: GatewayConnectionMetadata(
                    appVersion: appVersion, platform: platform, instanceID: credentials.instanceID))
        }
    }

    init(
        connectionFactory: @escaping @Sendable () async throws -> OpenClawGatewayConnection,
        monotonicMilliseconds: @escaping @Sendable () -> Double = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
        },
        timingSink: (@Sendable (LocalChatDeliveryTimingEvent) -> Void)? = nil)
    {
        self.connectionFactory = connectionFactory
        self.monotonicMilliseconds = monotonicMilliseconds
        self.timingSink = timingSink
    }

    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        guard !self.isActivating, !self.isDelivering else { throw ChatGatewayError.offline }
        self.isDelivering = true
        defer { self.isDelivering = false }
        let connection = try await self.readyConnection()
        var timing = LocalChatDeliveryTimer(startedAtMilliseconds: self.monotonicMilliseconds())
        do {
            // A previous process may have finished after the UI disconnected.
            // Recover its exact saved reply before asking the agent to run again.
            if let reply = try await connection.recoverReply(runID: entry.idempotencyKey) {
                let now = self.monotonicMilliseconds()
                if let event = timing.accepted(at: now) { self.recordTiming(event) }
                if let event = timing.firstText(in: reply, at: now) { self.recordTiming(event) }
                if let event = timing.terminal(outcome: .reply, at: now) { self.recordTiming(event) }
                self.logger.info("[gateway] recovered saved completion before send")
                await update(.accepted)
                await update(.reply(reply))
                return
            }
            let requestID = try await connection.sendMessage(
                entry.text,
                idempotencyKey: entry.idempotencyKey)
            var acceptedRunID: String?
            var eventsBeforeAcknowledgement: [GatewayConversationEvent] = []
            while true {
                var conversationEvents: [GatewayConversationEvent] = []
                switch try await connection.receive() {
                case let .response(id, ok, runID, status, error) where id == requestID:
                    guard ok else {
                        throw ChatGatewayError.gateway(error?.message ?? "Operator could not start this request")
                    }
                    let responseRunID = runID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    acceptedRunID = responseRunID?.isEmpty == false
                        ? responseRunID
                        : entry.idempotencyKey
                    if let event = timing.accepted(at: self.monotonicMilliseconds()) {
                        self.recordTiming(event)
                    }
                    await update(.accepted)
                    switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    case "ok":
                        guard let reply = try await connection.recoverReply(runID: acceptedRunID!) else {
                            self.logger.error(
                                "[gateway] exact terminal reply missing runID=\(acceptedRunID!, privacy: .public)")
                            await update(.failed("Operator finished, but its exact reply could not be recovered."))
                            return
                        }
                        let now = self.monotonicMilliseconds()
                        if let event = timing.firstText(in: reply, at: now) { self.recordTiming(event) }
                        if let event = timing.terminal(outcome: .reply, at: now) { self.recordTiming(event) }
                        await update(.reply(reply))
                        return
                    case "timeout", "error":
                        self.logger.error(
                            "[gateway] terminal chat acknowledgement status=\(status!, privacy: .public) runID=\(acceptedRunID!, privacy: .public)")
                        if let event = timing.terminal(
                            outcome: .failed, at: self.monotonicMilliseconds())
                        {
                            self.recordTiming(event)
                        }
                        await update(.failed("Operator could not complete this request."))
                        return
                    default:
                        break
                    }
                    conversationEvents = eventsBeforeAcknowledgement
                    eventsBeforeAcknowledgement.removeAll(keepingCapacity: false)
                case let .conversation(events):
                    guard acceptedRunID != nil else {
                        eventsBeforeAcknowledgement.append(contentsOf: events)
                        continue
                    }
                    conversationEvents = events
                case let .approval(event):
                    switch event.phase {
                    case .pending:
                        await self.publishApproval(.event(event))
                        guard event.approval.isActionable() else {
                            await self.publishApproval(.unsafe(
                                "Operator received an invalid or expired approval. Nothing was allowed."))
                            throw ChatGatewayError.gateway("Operator could not safely request your approval.")
                        }
                        self.logger.info("[approval] pending displayed; continuing to receive server updates id=\(event.approval.id, privacy: .public)")
                    case .terminal:
                        await self.publishApproval(.event(event))
                        self.logger.info("[approval] terminal received id=\(event.approval.id, privacy: .public)")
                    }
                case .response, .ignored:
                    continue
                }
                guard let acceptedRunID else { continue }
                for event in conversationEvents {
                    guard event.runID == acceptedRunID else {
                        self.logger.info(
                            "[gateway] ignored event for non-current run eventRun=\(event.runID, privacy: .public) currentRun=\(acceptedRunID, privacy: .public)")
                        continue
                    }
                    switch event {
                    case let .working(runID):
                        self.activeRunID = runID
                        await update(.working)
                    case let .stream(runID, text):
                        self.activeRunID = runID
                        if let event = timing.firstText(in: text, at: self.monotonicMilliseconds()) {
                            self.recordTiming(event)
                        }
                        await update(.stream(text))
                    case let .reply(_, text):
                        self.activeRunID = nil
                        let now = self.monotonicMilliseconds()
                        if let event = timing.firstText(in: text, at: now) {
                            self.recordTiming(event)
                        }
                        if let event = timing.terminal(outcome: .reply, at: now) {
                            self.recordTiming(event)
                        }
                        await update(.reply(text))
                        return
                    case let .failed(runID, message):
                        // A restart can emit failure for the old run while native
                        // recovery owns its continuation. Reconcile before clearing it.
                        if let reply = try await connection.recoverReply(runID: runID) {
                            self.activeRunID = nil
                            let now = self.monotonicMilliseconds()
                            if let event = timing.firstText(in: reply, at: now) { self.recordTiming(event) }
                            if let event = timing.terminal(outcome: .reply, at: now) { self.recordTiming(event) }
                            await update(.reply(reply))
                            return
                        }
                        self.activeRunID = nil
                        self.logger.error("[gateway] run failed id=\(runID, privacy: .public)")
                        if let event = timing.terminal(
                            outcome: .failed, at: self.monotonicMilliseconds())
                        {
                            self.recordTiming(event)
                        }
                        await update(.failed(message))
                        return
                    case .stopped:
                        self.activeRunID = nil
                        if let event = timing.terminal(
                            outcome: .stopped, at: self.monotonicMilliseconds())
                        {
                            self.recordTiming(event)
                        }
                        await update(.stopped)
                        return
                    }
                }
            }
        } catch {
            if let event = timing.terminal(outcome: .error, at: self.monotonicMilliseconds()) {
                self.recordTiming(event)
            }
            await connection.disconnect()
            self.connection = nil
            if error as? OpenClawGatewayError == .recoveryPending {
                self.logger.info("[gateway] retaining request until native recovery settles")
                throw ChatGatewayError.gateway("Operator is restoring this request.")
            }
            if let gatewayError = error as? ChatGatewayError {
                throw gatewayError
            }
            self.logger.error("[gateway] local delivery lost connection")
            throw ChatGatewayError.offline
        }
    }

    private nonisolated static func defaultMonotonicMilliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    private func recordTiming(_ event: LocalChatDeliveryTimingEvent) {
        let outcome = event.outcome?.rawValue ?? "none"
        self.logger.info(
            "[chat-timing] phase=\(event.phase.rawValue, privacy: .public) elapsedMs=\(event.elapsedMilliseconds) outcome=\(outcome, privacy: .public)")
        self.timingSink?(event)
    }

    func stop() async {
        guard let connection else { return }
        do {
            _ = try await connection.abort(runID: self.activeRunID)
        } catch {
            self.logger.error("[gateway] stop request failed")
        }
    }

    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    {
        guard !self.isActivating, !self.isDelivering, self.approvalRequestsInFlight == 0 else {
            self.logger.info("[gateway] foreground reconnect deferred while a request owns the connection")
            throw ChatGatewayError.offline
        }
        self.isActivating = true
        defer { self.isActivating = false }
        // A socket retained across iOS suspension may still claim connected.
        // Establish the foreground subscription on a new transport instead.
        await self.connection?.disconnect()
        self.connection = nil
        self.logger.info("[gateway] opening a fresh foreground subscription connection")
        let connection = try await self.readyConnection()
        do {
            let replay = try await connection.subscribeToSessionApprovals()
            self.approvalUpdate = update
            self.logger.info("[approval] applied server replay count=\(replay.approvals.count)")
            await update(.replay(replay))
        } catch {
            await connection.disconnect()
            self.connection = nil
            throw error
        }
    }

    func resolveApproval(
        id: String,
        kind: GatewayApprovalKind,
        decision: GatewayApprovalDecision) async throws -> GatewayApprovalSnapshot
    {
        guard !self.isActivating else { throw ChatGatewayError.offline }
        self.approvalRequestsInFlight += 1
        defer { self.approvalRequestsInFlight -= 1 }
        // The chat reader must keep receiving cancellation and expiry notices.
        // Use the same saved identity on a separate connection for this response.
        let control = try await self.connectionFactory()
        self.logger.info("[approval] opening decision connection id=\(id, privacy: .public)")
        do {
            try await control.connect()
            let result = try await control.resolveApproval(id: id, kind: kind, decision: decision)
            await control.disconnect()
            await self.publishApproval(.canonical(result.approval))
            return result.approval
        } catch {
            await control.disconnect()
            self.logger.error("[approval] decision failed id=\(id, privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
    }

    private func readyConnection() async throws -> OpenClawGatewayConnection {
        if let connection, await connection.isConnected {
            return connection
        }
        let connection = try await self.connectionFactory()
        do {
            try await connection.connect()
            self.connection = connection
            return connection
        } catch let error as OpenClawGatewayError {
            if case let .rejected(_, message) = error {
                throw ChatGatewayError.gateway(message)
            }
            throw ChatGatewayError.offline
        }
    }

    private func publishApproval(_ update: ChatApprovalUpdate) async {
        await self.approvalUpdate?(update)
    }

}
