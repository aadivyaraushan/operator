public enum RuntimeLifecycleState: Equatable, Sendable {
    case cold
    case starting
    case ready
    case suspending
    case suspended
    case failed(String)
}

public enum RuntimeLifecycleEvent: Equatable, Sendable {
    case becameActive
    case started
    case enteredBackground
    case snapshotSaved
    case failed(String)
}

public enum RuntimeLifecycleAction: Equatable, Sendable {
    case start
    case restoreSnapshot
    case prepareGatewaySuspend
    case saveSnapshot
}

public struct RuntimeLifecycleMachine: Sendable {
    public private(set) var state: RuntimeLifecycleState = .cold

    public init() {}

    public mutating func handle(_ event: RuntimeLifecycleEvent) -> [RuntimeLifecycleAction] {
        switch (self.state, event) {
        case (.cold, .becameActive), (.failed, .becameActive):
            self.state = .starting
            return [.start]
        case (.suspended, .becameActive):
            self.state = .starting
            return [.restoreSnapshot]
        case (.starting, .started):
            self.state = .ready
            return []
        case (.ready, .enteredBackground):
            self.state = .suspending
            return [.prepareGatewaySuspend, .saveSnapshot]
        case (.suspending, .snapshotSaved):
            self.state = .suspended
            return []
        case (_, let .failed(message)):
            self.state = .failed(message)
            return []
        default:
            return []
        }
    }
}
