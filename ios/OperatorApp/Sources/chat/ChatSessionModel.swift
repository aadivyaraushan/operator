import Combine
import Foundation
import OperatorCore
import OSLog

enum ConnectionState: Equatable {
    case starting
    case ready
    case working
    case offline

    var title: String {
        switch self {
        case .starting: "Starting Operator"
        case .ready: "Ready on this iPhone"
        case .working: "Working locally"
        case .offline: "Saved — waiting for Operator"
        }
    }

    var symbol: String {
        switch self {
        case .starting: "circle.dotted"
        case .ready: "checkmark.circle"
        case .working: "sparkles"
        case .offline: "clock.badge.exclamationmark"
        }
    }
}

@MainActor
final class ChatSessionModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var outbox: [OutboxEntry] = []
    @Published private(set) var streamingReply: String?
    @Published private(set) var approvals: [GatewayApprovalSnapshot] = []
    @Published private(set) var connectionState: ConnectionState = .starting
    @Published private(set) var lastError: String?

    let dictation: OfflineDictationModel

    private let store: any ChatPersistence
    private let gateway: any ChatGateway
    private let logger = Logger(subsystem: "app.operator.ios", category: "chat")
    private var isFlushing = false
    private var isRestoring = false
    private var hasRestored = false
    private var isForegroundActive = true
    private var reconnectTask: Task<Void, Never>?
    private var isConnecting = false
    private var isGatewayReady = false
    private var isRuntimeReady = false
    private var gatewayReadyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var approvalRecords: [String: GatewayApprovalSnapshot] = [:]

    init(
        store: any ChatPersistence,
        gateway: any ChatGateway,
        dictation: OfflineDictationModel? = nil
    ) {
        self.store = store
        self.gateway = gateway
        self.dictation = dictation ?? OfflineDictationModel(service: AppleOnDeviceDictationService())
    }

    func restore() {
        guard !self.isRestoring, !self.hasRestored else { return }
        self.isRestoring = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestoring = false }
            do {
                self.apply(try await self.store.restore())
                self.hasRestored = true
                self.connectionState = .starting
                self.startForegroundRecoveryIfNeeded()
            } catch {
                self.connectionState = .offline
                self.lastError = "Your saved conversation could not be opened."
                self.logger.error("[chat] local conversation restore failed")
            }
        }
    }

    func setForegroundActive(_ isActive: Bool) {
        self.isForegroundActive = isActive
        guard isActive else {
            self.isRuntimeReady = false
            self.isGatewayReady = false
            self.resumeGatewayReadyWaiters(with: false)
            self.reconnectTask?.cancel()
            return
        }
        self.startForegroundRecoveryIfNeeded()
    }

    func runtimeIsStarting() {
        self.isRuntimeReady = false
        self.resetGatewayReadiness()
        self.reconnectTask?.cancel()
        self.connectionState = .starting
        self.lastError = nil
        self.logger.info("[runtime] waiting for local runtime before opening chat")
    }

    func runtimeBecameReady() {
        guard !self.isRuntimeReady else { return }
        self.isRuntimeReady = true
        self.connectionState = .starting
        self.lastError = nil
        self.logger.info("[runtime] local runtime ready; chat may connect while foreground")
        self.restore()
        self.startForegroundRecoveryIfNeeded()
    }

    func runtimeDidSuspend() {
        self.setForegroundActive(false)
        self.connectionState = .offline
    }

    func runtimeFailed(_ message: String) {
        self.isRuntimeReady = false
        self.resetGatewayReadiness()
        self.reconnectTask?.cancel()
        self.connectionState = .offline
        self.lastError = message
        self.logger.error("[runtime] local runtime failed; chat connection gate closed")
    }

    func restoreAndWaitForGatewayReady() async -> Bool {
        self.restore()
        guard self.isForegroundActive else { return false }
        if self.isGatewayReady { return true }
        return await withCheckedContinuation { continuation in
            self.gatewayReadyWaiters.append(continuation)
        }
    }

    func resetGatewayReadiness() {
        self.isGatewayReady = false
        self.resumeGatewayReadyWaiters(with: false)
    }

    func updateDraft(_ text: String) {
        self.draft = text
        self.dictation.noteDraftChanged(text)
        Task { [store, logger] in
            do {
                _ = try await store.saveDraft(text)
            } catch {
                logger.error("[chat] local draft save failed length=\(text.count)")
            }
        }
    }

    func send() {
        let trimmed = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = UUID()
        let now = Date()
        self.draft = ""
        self.messages.append(ChatMessage(
            id: id,
            role: .user,
            text: trimmed,
            createdAt: now,
            delivery: .waiting))
        self.outbox.append(OutboxEntry(
            id: id,
            messageID: id,
            text: trimmed,
            idempotencyKey: id.uuidString.lowercased(),
            state: .waiting))
        self.streamingReply = nil
        self.lastError = nil
        self.connectionState = self.isGatewayReady ? .working : .offline
        self.logger.info("[chat] staged input id=\(id.uuidString, privacy: .public) characters=\(trimmed.count)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.apply(try await self.store.stage(id: id, text: trimmed, now: now))
                await self.flushOutbox()
            } catch {
                self.connectionState = .offline
                self.lastError = "This message is visible, but could not be saved yet."
                self.logger.error("[chat] message persistence failed id=\(id.uuidString, privacy: .public)")
            }
        }
    }

    func stop() {
        Task { [gateway] in
            await gateway.stop()
        }
    }

    func recordWeatherCard(_ card: WeatherCard) async throws {
        self.apply(try await self.store.appendWeatherCard(card))
        self.logger.info("[chat] weather card persisted")
    }

    func resolveApproval(id: String, decision: GatewayApprovalDecision) {
        guard let approval = self.approvalRecords[id],
              approval.isActionable(),
              approval.presentation.allowedDecisions.contains(decision)
        else {
            self.lastError = "That approval is no longer safe to answer. It was not sent."
            self.logger.error("[approval] rejected local action for missing or unsafe approval")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.gateway.resolveApproval(
                    id: id,
                    kind: approval.presentation.kind,
                    decision: decision)
                self.applyApproval(snapshot)
            } catch {
                self.lastError = "Operator could not record that approval. Nothing was allowed."
                self.logger.error("[approval] server resolution failed id=\(id, privacy: .public)")
            }
        }
    }

    func startDictation() {
        self.dictation.start(draft: self.draft) { [weak self] draft in
            self?.updateDraft(draft)
        }
    }

    func stopDictation() {
        self.dictation.stop()
    }

    private func flushOutbox() async {
        guard self.isRuntimeReady, self.isGatewayReady, self.isForegroundActive,
              !self.isFlushing, !self.isConnecting else { return }
        self.isFlushing = true
        var shouldReconnectAfterFlush = false
        defer {
            self.isFlushing = false
            if shouldReconnectAfterFlush || !self.isGatewayReady {
                self.startForegroundRecoveryIfNeeded()
            }
        }

        while self.isRuntimeReady, self.isGatewayReady, self.isForegroundActive, let entry = self.outbox.first {
            do {
                self.apply(try await self.store.markSending(id: entry.id))
                self.connectionState = .working
                try await self.gateway.deliver(entry) { [weak self] update in
                    await self?.handle(update, entryID: entry.id)
                }
                if self.outbox.contains(where: { $0.id == entry.id }) {
                    break
                }
            } catch {
                do {
                    self.apply(try await self.store.markWaiting(id: entry.id))
                } catch {
                    self.logger.error("[chat] could not return interrupted request to outbox")
                }
                self.isGatewayReady = false
                self.connectionState = .offline
                self.lastError = Self.userMessage(for: error)
                self.streamingReply = nil
                self.logger.error("[chat] delivery paused id=\(entry.id.uuidString, privacy: .public)")
                shouldReconnectAfterFlush = true
                break
            }
        }
    }

    private func startForegroundRecoveryIfNeeded() {
        guard self.hasRestored,
              self.isRuntimeReady,
              self.isForegroundActive,
              !self.isConnecting,
              !self.isFlushing,
              self.reconnectTask == nil
        else { return }
        self.reconnectTask = Task { @MainActor [weak self] in
            await self?.recoverWhileForeground()
        }
    }

    private func recoverWhileForeground() async {
        defer {
            self.reconnectTask = nil
            if self.isForegroundActive,
               (Task.isCancelled || self.connectionState == .offline)
            {
                self.startForegroundRecoveryIfNeeded()
            }
        }

        while self.isRuntimeReady, self.isForegroundActive, !Task.isCancelled {
            do {
                self.isConnecting = true
                try await self.gateway.activateApprovalUpdates { [weak self] update in
                    await self?.handleApproval(update)
                }
                self.isConnecting = false
                guard self.isRuntimeReady, self.isForegroundActive, !Task.isCancelled else {
                    self.connectionState = .offline
                    return
                }

                self.connectionState = self.outbox.isEmpty ? .ready : .working
                self.isGatewayReady = true
                self.resumeGatewayReadyWaiters(with: true)
                self.lastError = nil
                self.logger.info("[gateway] foreground connection restored")
                await self.flushOutbox()
                if self.connectionState != .offline {
                    return
                }
            } catch {
                self.isConnecting = false
                self.isGatewayReady = false
                self.connectionState = .offline
                self.logger.error("[gateway] foreground connection unavailable; will retry while active")
            }

            guard self.isForegroundActive, !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func handle(_ update: ChatDeliveryUpdate, entryID: UUID) async {
        do {
            switch update {
            case .accepted, .working:
                self.connectionState = .working
            case let .stream(text):
                self.streamingReply = text
                self.connectionState = .working
            case let .reply(text):
                self.apply(try await self.store.markAccepted(id: entryID))
                self.apply(try await self.store.appendAssistant(text))
                self.streamingReply = nil
                self.connectionState = .ready
                self.logger.info("[chat] reply persisted for id=\(entryID.uuidString, privacy: .public)")
            case let .failed(message):
                self.apply(try await self.store.markAccepted(id: entryID))
                self.streamingReply = nil
                self.lastError = message
                self.connectionState = .ready
            case .stopped:
                self.apply(try await self.store.markAccepted(id: entryID))
                self.streamingReply = nil
                self.connectionState = .ready
            }
        } catch {
            self.connectionState = .offline
            self.lastError = "Operator replied, but the result could not be saved."
            self.logger.error("[chat] delivery update persistence failed")
        }
    }

    private func resumeGatewayReadyWaiters(with value: Bool) {
        let waiters = self.gatewayReadyWaiters
        self.gatewayReadyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    private func apply(_ snapshot: ConversationSnapshot) {
        self.messages = snapshot.messages
        self.outbox = snapshot.outbox
        self.draft = snapshot.draft
    }

    private func handleApproval(_ update: ChatApprovalUpdate) {
        switch update {
        case let .replay(replay):
            guard !replay.truncated else {
                self.approvalRecords.removeAll()
                self.approvals = []
                self.lastError = "Operator has too many pending approvals to show safely."
                self.logger.error("[approval] rejected truncated approval replay")
                return
            }
            var replayRecords: [String: GatewayApprovalSnapshot] = [:]
            for approval in replay.approvals {
                guard approval.status == .pending,
                      approval.isActionable(),
                      replayRecords[approval.id] == nil
                else {
                    self.approvalRecords.removeAll()
                    self.approvals = []
                    self.lastError = "An approval was invalid or expired, so Operator did not show it."
                    self.logger.error("[approval] rejected unsafe replay item")
                    return
                }
                replayRecords[approval.id] = approval
            }
            self.approvalRecords = replayRecords
            self.refreshApprovals()
        case let .event(event):
            self.applyApproval(event.approval)
        case let .canonical(approval):
            self.applyApproval(approval)
        case let .unsafe(message):
            self.lastError = message
            self.logger.error("[approval] gateway rejected unsafe approval frame")
        }
    }

    private func applyApproval(_ approval: GatewayApprovalSnapshot) {
        guard approval.status != .pending || approval.isActionable() else {
            self.approvalRecords.removeValue(forKey: approval.id)
            self.refreshApprovals()
            self.lastError = "That approval expired or was invalid. It was not sent."
            self.logger.error("[approval] removed non-actionable pending approval id=\(approval.id, privacy: .public)")
            return
        }
        self.approvalRecords[approval.id] = approval
        self.refreshApprovals()
    }

    private func refreshApprovals() {
        self.approvals = self.approvalRecords.values
            .filter { $0.status == .pending && $0.isActionable() }
            .sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
    }

    private static func userMessage(for error: Error) -> String {
        if case let ChatGatewayError.gateway(message) = error {
            return message
        }
        return "Operator will send this automatically when the local runtime is ready."
    }
}
