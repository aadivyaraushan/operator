import Combine
import Foundation
import OperatorCore
import os
import OSLog

/// A grant the agent wanted and did not have. Shown in chat so the owner can
/// allow it at the moment it would have been useful, which is also the moment
/// iOS itself would have asked for the matching system permission.
struct ConnectorGrantRequest: Equatable, Sendable {
    let connector: ConnectorID
    let access: ConnectorAccess
    let command: String
}

/// One thing the node did this session, for the "what did it read" list.
struct ConnectorActivityRecord: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case ran, denied, failed }
    let id: UUID
    let date: Date
    let connector: ConnectorID
    let access: ConnectorAccess
    let command: String
    let outcome: Outcome
}

/// Where grants persist. UserDefaults is enough: these are the owner's own
/// choices about their own phone, not secrets, and they should survive a
/// reinstall no more than the rest of the app's state does.
protocol ConnectorGrantStore: AnyObject, Sendable {
    func loadGrants() -> ConnectorGrants?
    func saveGrants(_ grants: ConnectorGrants)
    func loadOnboardingComplete() -> Bool
    func saveOnboardingComplete(_ complete: Bool)
}

final class UserDefaultsConnectorGrantStore: ConnectorGrantStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let grantsKey = "app.operator.connectorGrants"
    private let onboardingKey = "app.operator.connectorGrants.onboardingComplete"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadGrants() -> ConnectorGrants? {
        guard let data = self.defaults.data(forKey: self.grantsKey) else { return nil }
        // A file this app cannot read is treated as "nothing granted", never
        // as "everything granted".
        return try? JSONDecoder().decode(ConnectorGrants.self, from: data)
    }

    func saveGrants(_ grants: ConnectorGrants) {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        self.defaults.set(data, forKey: self.grantsKey)
    }

    func loadOnboardingComplete() -> Bool { self.defaults.bool(forKey: self.onboardingKey) }
    func saveOnboardingComplete(_ complete: Bool) { self.defaults.set(complete, forKey: self.onboardingKey) }
}

/// The owner's grants, live. Every node command is checked here before it
/// runs, the model's tool list is derived from here, and the Permissions
/// page edits here. Nothing else in the app decides what the agent may do.
@MainActor
final class ConnectorPermissionCenter: ObservableObject {
    @Published private(set) var grants: ConnectorGrants
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var pendingRequest: ConnectorGrantRequest?
    @Published private(set) var activity: [ConnectorActivityRecord] = []
    /// A grant waiting on the owner to accept its warning. Set instead of the
    /// grant whenever the connector carries an acknowledgement for that side;
    /// the grant is written only by acceptAcknowledgement().
    @Published private(set) var acknowledgementRequired: PendingAcknowledgement?

    struct PendingAcknowledgement: Equatable, Sendable {
        let connector: ConnectorID
        let access: ConnectorAccess
        var acknowledgement: ConnectorAcknowledgement? { ConnectorCatalog.descriptor(self.connector).acknowledgement(for: self.access) }
    }

    /// Called after every change so the node can re-offer the model its tools.
    var grantsDidChange: (@MainActor () -> Void)?

    private let store: any ConnectorGrantStore
    private let now: () -> Date
    /// The node publishes tools from a @Sendable closure off the main actor;
    /// it reads this copy, which every change updates.
    private nonisolated let snapshot: OSAllocatedUnfairLock<ConnectorGrants>
    private let logger = Logger(subsystem: "app.operator.ios", category: "permissions")
    static let activityLimit = 200
    /// Node commands refused for a missing grant, held until the owner
    /// answers the banner. Resolved true when the grant lands, false when
    /// the ask is dismissed, declined, or the wait runs out.
    private struct DecisionWaiter {
        let connector: ConnectorID
        let access: ConnectorAccess
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var decisionWaiters: [UUID: DecisionWaiter] = [:]

    init(store: any ConnectorGrantStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        let grants = store.loadGrants() ?? .none
        self.grants = grants
        self.snapshot = OSAllocatedUnfairLock(initialState: grants)
        self.hasCompletedOnboarding = store.loadOnboardingComplete()
    }

    /// What the model should be offered, readable from any thread.
    nonisolated func currentPublishedTools() -> [GatewayNodeAgentToolDescriptor] {
        GatewayNodeAgentTools.descriptors(permittedBy: self.snapshot.withLock { $0 })
    }

    // MARK: Editing

    func isGranted(_ id: ConnectorID, _ access: ConnectorAccess) -> Bool { self.grants.isGranted(id, access) }

    /// The one entry point for turning a grant on or off from the UI. A grant
    /// that carries an acknowledgement is not written here; it becomes the
    /// pending acknowledgement, and the grant lands only if the owner accepts.
    func requestGrant(_ id: ConnectorID, _ access: ConnectorAccess, allowed: Bool) {
        if allowed, ConnectorCatalog.descriptor(id).acknowledgement(for: access) != nil {
            self.acknowledgementRequired = PendingAcknowledgement(connector: id, access: access)
            self.logger.info("[permissions] acknowledgement required connector=\(id.rawValue, privacy: .public) access=\(access.rawValue, privacy: .public)")
            return
        }
        self.set(id, access, allowed: allowed)
    }

    func acceptAcknowledgement() {
        guard let pending = self.acknowledgementRequired else { return }
        self.acknowledgementRequired = nil
        self.logger.info("[permissions] acknowledgement accepted connector=\(pending.connector.rawValue, privacy: .public) access=\(pending.access.rawValue, privacy: .public)")
        self.set(pending.connector, pending.access, allowed: true)
    }

    func declineAcknowledgement() {
        if let pending = self.acknowledgementRequired {
            self.logger.info("[permissions] acknowledgement declined connector=\(pending.connector.rawValue, privacy: .public)")
            self.resolveDecisionWaiters(false) { $0.connector == pending.connector && $0.access == pending.access }
        }
        self.acknowledgementRequired = nil
    }

    func set(_ id: ConnectorID, _ access: ConnectorAccess, allowed: Bool) {
        var updated = self.grants
        updated.set(id, access, allowed: allowed)
        self.apply(updated)
        self.logger.info("[permissions] \(allowed ? "granted" : "revoked", privacy: .public) connector=\(id.rawValue, privacy: .public) access=\(access.rawValue, privacy: .public)")
    }

    func setReadOnly(_ readOnly: Bool) {
        var updated = self.grants
        updated.readOnly = readOnly
        self.apply(updated)
        self.logger.info("[permissions] readOnly=\(readOnly)")
    }

    func completeOnboarding() {
        self.hasCompletedOnboarding = true
        self.store.saveOnboardingComplete(true)
    }

    private func apply(_ updated: ConnectorGrants) {
        guard updated != self.grants else { return }
        self.grants = updated
        self.snapshot.withLock { $0 = updated }
        self.store.saveGrants(updated)
        if let pending = self.pendingRequest, updated.permits(pending.connector, pending.access) {
            self.pendingRequest = nil
        }
        self.grantsDidChange?()
        self.resolveDecisionWaiters(true) { updated.permits($0.connector, $0.access) }
    }

    // MARK: In-context requests

    /// Returns false when the grant needs the owner to read a warning first;
    /// the caller then shows the Permissions page, which presents it.
    @discardableResult
    func allowPendingRequest() -> Bool {
        guard let pending = self.pendingRequest else { return true }
        self.requestGrant(pending.connector, pending.access, allowed: true)
        if self.acknowledgementRequired != nil { return false }
        self.pendingRequest = nil
        return true
    }

    func dismissPendingRequest() {
        self.pendingRequest = nil
        self.resolveDecisionWaiters(false) { _ in true }
    }

    /// Holds a refused command until the owner answers the banner it raised.
    /// True means the grant now exists and the command may run; false means
    /// it was dismissed, declined, or nobody answered within `limit`.
    func waitForDecision(connector: ConnectorID, access: ConnectorAccess, upTo limit: Duration) async -> Bool {
        if self.grants.permits(connector, access) { return true }
        guard limit > .zero else { return false }
        let id = UUID()
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let waiter = self?.decisionWaiters.removeValue(forKey: id) else { return }
            self?.logger.info("[permissions] wait ran out connector=\(connector.rawValue, privacy: .public) access=\(access.rawValue, privacy: .public)")
            waiter.continuation.resume(returning: false)
        }
        let allowed = await withCheckedContinuation { continuation in
            self.decisionWaiters[id] = DecisionWaiter(connector: connector, access: access, continuation: continuation)
        }
        timeout.cancel()
        return allowed
    }

    private func resolveDecisionWaiters(_ allowed: Bool, where matches: (DecisionWaiter) -> Bool) {
        for (id, waiter) in self.decisionWaiters where matches(waiter) {
            self.decisionWaiters[id] = nil
            waiter.continuation.resume(returning: allowed)
        }
    }

    // MARK: Enforcement

    /// The one check every node command passes through. A denial is recorded
    /// as the pending request the chat surfaces, so the owner sees the ask in
    /// context rather than a refusal after the fact.
    func authorize(_ command: String, paramsJSON: String?) -> ConnectorPermissionDecision {
        let decision = self.grants.decision(for: command, paramsJSON: paramsJSON)
        switch decision {
        case let .allowed(connector?, access?):
            self.record(connector, access, command, .ran)
        case .allowed:
            break
        case let .denied(connector, access):
            self.record(connector, access, command, .denied)
            self.pendingRequest = ConnectorGrantRequest(connector: connector, access: access, command: command)
            self.logger.info("[permissions] denied connector=\(connector.rawValue, privacy: .public) access=\(access.rawValue, privacy: .public) command=\(command, privacy: .public)")
        case .unknownCommand:
            self.logger.error("[permissions] unknown command refused command=\(command, privacy: .public)")
        }
        return decision
    }

    /// Something outside the node reported how an action ended - today, the
    /// Send Message shortcut coming back over x-callback.
    func recordExternalOutcome(connector: ConnectorID, access: ConnectorAccess, command: String, succeeded: Bool) {
        self.record(connector, access, command, succeeded ? .ran : .failed)
        self.logger.info("[permissions] external outcome connector=\(connector.rawValue, privacy: .public) succeeded=\(succeeded)")
    }

    private func record(_ connector: ConnectorID, _ access: ConnectorAccess, _ command: String, _ outcome: ConnectorActivityRecord.Outcome) {
        self.activity.insert(
            ConnectorActivityRecord(id: UUID(), date: self.now(), connector: connector, access: access, command: command, outcome: outcome),
            at: 0)
        if self.activity.count > Self.activityLimit { self.activity.removeLast(self.activity.count - Self.activityLimit) }
    }

    /// What the model is offered right now.
    var publishedTools: [GatewayNodeAgentToolDescriptor] {
        GatewayNodeAgentTools.descriptors(permittedBy: self.grants)
    }
}

/// Sits in front of the command router. Nothing reaches a connector without a
/// grant, and the model is told plainly what to do about a refusal.
@MainActor
final class PermissionGuardedNodeCommandHandler: GatewayNodeCommandHandler {
    private let center: ConnectorPermissionCenter
    private let next: any GatewayNodeCommandHandler
    private let maximumDecisionWait: Duration
    private let logger = Logger(subsystem: "app.operator.ios", category: "permissions")

    init(center: ConnectorPermissionCenter, next: any GatewayNodeCommandHandler, maximumDecisionWait: Duration = .seconds(45)) {
        self.center = center
        self.next = next
        self.maximumDecisionWait = maximumDecisionWait
    }

    /// How long a refused command may wait for the owner. It must answer
    /// before the gateway gives up on it, so it stays three seconds inside
    /// the gateway's own timeout, and assumes a short one when none is sent.
    static func decisionWait(maximum: Duration, timeoutMilliseconds: Int?) -> Duration {
        let budget: Duration = timeoutMilliseconds.map { .milliseconds(max(0, $0 - 3_000)) } ?? .seconds(25)
        return min(maximum, budget)
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        switch self.center.authorize(command, paramsJSON: paramsJSON) {
        case .allowed:
            return await self.next.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case let .denied(connector, access):
            // The banner is up. Hold the call for the owner's answer so an
            // Allow continues the task instead of costing a second ask.
            let wait = Self.decisionWait(maximum: self.maximumDecisionWait, timeoutMilliseconds: timeoutMilliseconds)
            self.logger.info("[permissions] waiting for the owner connector=\(connector.rawValue, privacy: .public) access=\(access.rawValue, privacy: .public) command=\(command, privacy: .public) upTo=\(wait.components.seconds)s")
            if await self.center.waitForDecision(connector: connector, access: access, upTo: wait),
               case .allowed = self.center.authorize(command, paramsJSON: paramsJSON) {
                self.logger.info("[permissions] allowed while waiting; running command=\(command, privacy: .public)")
                return await self.next.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            }
            let title = ConnectorCatalog.descriptor(connector).title
            return .failure(
                code: "PERMISSION_DENIED",
                message: "The person has not allowed Operator to \(access.rawValue) \(title) on this iPhone. They have just been shown a prompt to allow it; tell them what you wanted to do and that they can allow it there or in Settings, then stop. Do not retry until they say so.")
        case .unknownCommand:
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
    }
}
