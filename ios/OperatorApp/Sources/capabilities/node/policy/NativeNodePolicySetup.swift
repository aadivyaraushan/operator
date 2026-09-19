import Foundation
import OperatorCore
import OSLog

actor NativeNodePolicySetup {
    private let connectionFactory: @Sendable () async throws -> OpenClawGatewayConnection
    private var didAttemptWrite = false
    private let logger = Logger(subsystem: "app.operator.ios", category: "native-node-policy")

    init(connectionFactory: @escaping @Sendable () async throws -> OpenClawGatewayConnection) {
        self.connectionFactory = connectionFactory
    }

    func prepare() async throws -> Bool {
        let control = try await self.connectionFactory()
        do {
            try await control.connect()
            let state = try await control.nativeNodePolicyState()
            let ready: Bool
            switch state {
            case .ready:
                ready = true
                self.logger.info("[node-policy] compose permission is applied")
            case .waitingForApply:
                ready = false
                self.logger.info("[node-policy] waiting for configured permission to be applied")
            case let .missing(baseHash, existingAllow):
                ready = false
                if !self.didAttemptWrite {
                    // A lost response can still mean the write succeeded. Never
                    // issue it twice in this app instance; check fresh state instead.
                    self.didAttemptWrite = true
                    self.logger.info("[node-policy] adding missing native command permissions")
                    try await control.installNativeNodeAllowPolicy(baseHash: baseHash, existingAllow: existingAllow)
                } else {
                    self.logger.error("[node-policy] earlier write remains unverified; no repeat write")
                }
            }
            await control.disconnect()
            return ready
        } catch {
            await control.disconnect()
            self.logger.error("[node-policy] setup check failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
    }
}
