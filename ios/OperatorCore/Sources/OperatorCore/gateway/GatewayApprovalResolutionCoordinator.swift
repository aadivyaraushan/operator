import Foundation

/// Coordinates a pending Gateway approval with the task that is waiting for it.
/// A terminal event can arrive while the UI callback temporarily yields the actor.
public struct GatewayApprovalResolutionCoordinator: Sendable {
    private static let retainedTerminalLimit = 64

    private var pendingIDs: Set<String> = []
    private var waitingIDs: Set<String> = []
    private var rememberedResolutionIDs: Set<String> = []
    private var terminalIDs: Set<String> = []
    private var terminalOrder: [String] = []

    public init() {}

    /// Records a newly observed pending approval. Terminal IDs are never reused.
    public mutating func notePending(id: String) {
        guard !id.isEmpty, !self.terminalIDs.contains(id) else { return }
        self.pendingIDs.insert(id)
    }

    /// Returns true only when the caller must install a continuation.
    public mutating func beginWaiting(id: String) -> Bool {
        if self.rememberedResolutionIDs.remove(id) != nil {
            return false
        }
        guard self.pendingIDs.contains(id) else { return false }
        self.waitingIDs.insert(id)
        return true
    }

    /// Records a terminal result and returns true only when an installed waiter needs resuming.
    public mutating func recordResolution(id: String) -> Bool {
        guard self.pendingIDs.remove(id) != nil else { return false }
        self.rememberTerminal(id: id)
        if self.waitingIDs.remove(id) != nil {
            return true
        }
        self.rememberedResolutionIDs.insert(id)
        return false
    }

    var rememberedResolutionCount: Int {
        self.rememberedResolutionIDs.count
    }

    private mutating func rememberTerminal(id: String) {
        guard self.terminalIDs.insert(id).inserted else { return }
        self.terminalOrder.append(id)
        guard self.terminalOrder.count > Self.retainedTerminalLimit else { return }
        let expired = self.terminalOrder.removeFirst()
        self.terminalIDs.remove(expired)
        self.rememberedResolutionIDs.remove(expired)
    }
}
