import Combine
import Foundation
import OperatorCore
import OSLog

protocol WhatsAppLinkFlowGateway: Sendable {
    func start(phone: String) async throws -> WhatsAppLinkOperation
    func status(operationID: String) async throws -> WhatsAppLinkStatus
    func cancel(operationID: String) async throws -> WhatsAppLinkOperation
}

extension WhatsAppLinkGatewayClient: WhatsAppLinkFlowGateway {}

enum WhatsAppLinkFlowState: Equatable {
    case idle
    case starting
    case waitingForCode
    case codeReady
    case finishing
    case cancelled
    case failed
    case linked

    var phase: WhatsAppLinkPhase? {
        switch self {
        case .idle, .starting: nil
        case .waitingForCode: .waitingForCode
        case .codeReady: .codeReady
        case .finishing: .finishing
        case .cancelled: .cancelled
        case .failed: .failed
        case .linked: .linked
        }
    }

    var isTerminal: Bool {
        switch self {
        case .cancelled, .failed, .linked: true
        default: false
        }
    }
}

@MainActor
final class WhatsAppLinkFlowModel: ObservableObject {
    @Published private(set) var state: WhatsAppLinkFlowState = .idle
    @Published private(set) var isPresented = false
    @Published private(set) var pairCode: String?
    @Published private(set) var operationID: String?
    @Published private(set) var phoneError: String?
    @Published private(set) var failureMessage: String?

    private static let logger = Logger(subsystem: "app.operator.ios", category: "whatsapp-link")

    private let gateway: any WhatsAppLinkFlowGateway
    private let pollInterval: Duration
    private var responseGeneration = 0
    private var startID = 0
    private var isClosed = false
    private var cancelAfterStartID: Int?
    private var isForeground = true
    private var pollingTask: Task<Void, Never>?

    init(gateway: any WhatsAppLinkFlowGateway, pollInterval: Duration = .seconds(2)) {
        self.gateway = gateway
        self.pollInterval = pollInterval
    }

    func present() {
        guard !self.isPresented else { return }
        self.isClosed = false
        self.cancelAfterStartID = nil
        self.state = .idle
        self.pairCode = nil
        self.operationID = nil
        self.isPresented = true
    }

    func start(phone: String) async {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "().-‐‑–—"))
        let normalized = String(phone.unicodeScalars.filter { !separators.contains($0) })
        guard normalized.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil else {
            self.phoneError = "Include + and your country code. Spaces, parentheses and dashes are fine; leave out extensions."
            self.state = .idle
            Self.logger.info("[whatsapp-link] phone input rejected: invalid international format")
            return
        }
        self.phoneError = nil
        self.failureMessage = nil
        Self.logger.info("[whatsapp-link] phone format accepted; requesting pairing")
        self.responseGeneration &+= 1
        let generation = self.responseGeneration
        self.startID &+= 1
        let startID = self.startID
        self.stopPolling()
        self.isClosed = false
        self.cancelAfterStartID = nil
        self.pairCode = nil
        self.operationID = nil
        self.state = .starting
        self.isPresented = true
        do {
            let operation = try await self.gateway.start(phone: normalized)
            if self.isClosed {
                if self.cancelAfterStartID == startID {
                    self.cancelAfterStartID = nil
                    _ = try? await self.gateway.cancel(operationID: operation.operationID)
                }
                return
            }
            guard startID == self.startID else { return }
            self.operationID = operation.operationID
            guard generation == self.responseGeneration else { return }
            self.apply(phase: operation.phase, pairCode: nil)
            self.schedulePollIfNeeded()
        } catch {
            guard !self.isClosed, generation == self.responseGeneration else { return }
            self.pairCode = nil
            self.state = .failed
        }
    }

    func refresh() async {
        guard self.isForeground, let operationID = self.operationID, !self.isClosed else { return }
        let generation = self.responseGeneration
        do {
            let status = try await self.gateway.status(operationID: operationID)
            guard !self.isClosed,
                  generation == self.responseGeneration,
                  self.operationID == operationID,
                  status.operationID == operationID
            else { return }
            self.apply(phase: status.phase, pairCode: status.pairCode)
            if status.phase == .failed {
                switch status.failureCode {
                case "verification_required":
                    self.failureMessage = "WhatsApp requires extra verification that this connection cannot complete yet."
                case "code_expired":
                    self.failureMessage = "This link code expired. Try again to request a new one."
                case "client_outdated":
                    self.failureMessage = "The WhatsApp connection needs an update before it can link."
                default:
                    self.failureMessage = "WhatsApp could not finish linking. Try again or check your connection."
                }
                Self.logger.error("[whatsapp-link] pairing failed category=\(status.failureCode ?? "pairing_failed", privacy: .public)")
            }
            self.schedulePollIfNeeded()
        } catch {
            guard !self.isClosed,
                  generation == self.responseGeneration,
                  self.operationID == operationID
            else { return }
            self.pairCode = nil
            self.state = .failed
        }
    }

    func setForegroundActive(_ isActive: Bool) async {
        self.isForeground = isActive
        guard !isActive else {
            await self.refresh()
            return
        }
        guard !self.state.isTerminal else { return }
        self.responseGeneration &+= 1
        self.stopPolling()
        self.pairCode = nil
        self.state = .waitingForCode
    }

    func cancel() async {
        guard !self.isClosed else { return }
        self.isClosed = true
        self.responseGeneration &+= 1
        let cancellationGeneration = self.responseGeneration
        self.stopPolling()
        self.pairCode = nil
        guard let operationID = self.operationID else {
            self.cancelAfterStartID = self.startID
            self.finish(.cancelled)
            self.isPresented = false
            return
        }
        do {
            _ = try await self.gateway.cancel(operationID: operationID)
            guard self.isClosed,
                  cancellationGeneration == self.responseGeneration,
                  self.operationID == operationID
            else { return }
            self.finish(.cancelled)
            self.isPresented = false
        } catch {
            guard self.isClosed,
                  cancellationGeneration == self.responseGeneration,
                  self.operationID == operationID
            else { return }
            self.isClosed = false
            self.operationID = operationID
            self.state = .failed
        }
    }

    func dismissTerminalState() {
        guard self.state.isTerminal else { return }
        self.isPresented = false
    }

    func retry(phone: String) async {
        if self.operationID != nil {
            self.state = .waitingForCode
            await self.refresh()
        } else {
            await self.start(phone: phone)
        }
    }

    private func apply(phase: WhatsAppLinkPhase, pairCode: String?) {
        switch phase {
        case .waitingForCode:
            self.pairCode = nil
            self.state = .waitingForCode
        case .codeReady:
            self.pairCode = pairCode
            self.state = .codeReady
        case .finishing:
            self.pairCode = nil
            self.state = .finishing
        case .cancelled:
            self.finish(.cancelled)
        case .failed:
            self.finish(.failed)
        case .linked:
            self.finish(.linked)
        }
    }

    private func finish(_ state: WhatsAppLinkFlowState) {
        self.stopPolling()
        self.pairCode = nil
        self.operationID = nil
        self.state = state
    }

    private func schedulePollIfNeeded() {
        guard self.isForeground,
              !self.isClosed,
              !self.state.isTerminal,
              self.operationID != nil
        else { return }
        self.stopPolling()
        let generation = self.responseGeneration
        let delay = self.pollInterval
        self.pollingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.poll(generation: generation)
        }
    }

    private func poll(generation: Int) async {
        self.pollingTask = nil
        guard self.isForeground,
              !self.isClosed,
              !self.state.isTerminal,
              generation == self.responseGeneration
        else { return }
        await self.refresh()
    }

    private func stopPolling() {
        self.pollingTask?.cancel()
        self.pollingTask = nil
    }
}
