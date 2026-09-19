import Foundation
import OSLog

@MainActor
final class EmbeddedRuntimeHost {
    enum Failure: LocalizedError {
        case unavailable, stopped, timedOut
        var errorDescription: String? {
            switch self {
            case .unavailable: "Operator’s bundled runtime could not start. Please reopen the app."
            case .stopped: "Operator’s local runtime stopped. Please reopen the app."
            case .timedOut: "Operator is taking longer to start. Reopen the app to check again."
            }
        }
    }
    private struct Status: Decodable { let runID: String; let status: String }
    let runID: String
    let gatewayPort: UInt16
    private let launch: (String) throws -> Void
    private let readStatus: () throws -> Data?
    private var started = false
    private var launchFailed = false
    private let logger = Logger(subsystem: "app.operator.ios", category: "embedded-runtime")

    init(runID: String, gatewayPort: UInt16, launch: @escaping (String) throws -> Void, readStatus: @escaping () throws -> Data?) {
        self.runID = runID
        self.gatewayPort = gatewayPort
        self.launch = launch
        self.readStatus = readStatus
    }

    func start(token: String) throws {
        if launchFailed { throw Failure.unavailable }
        guard !started else { return }
        started = true
        logger.info("[embedded-runtime] starting run=\(self.runID, privacy: .public)")
        do { try launch(token) }
        catch {
            launchFailed = true
            let cause = error as NSError
            logger.error("[embedded-runtime] launch failed run=\(self.runID, privacy: .public) domain=\(cause.domain, privacy: .public) code=\(cause.code)")
            throw Failure.unavailable
        }
    }

    func isReady() throws -> Bool {
        guard started, !launchFailed else { return false }
        guard let data = try readStatus(), let status = try? JSONDecoder().decode(Status.self, from: data),
              status.runID == runID else { return false }
        if status.status == "failed" { throw Failure.stopped }
        return status.status == "ready"
    }

    func waitUntilReady(token: String) async throws {
        try start(token: token)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var polls = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if try isReady() {
                logger.info("[embedded-runtime] ready run=\(self.runID, privacy: .public)")
                return
            }
            polls += 1
            // A wait that is not ending is otherwise silent; say what the
            // status file holds every ten seconds so it can be read from the log.
            if polls % 66 == 0 {
                let status = (try? readStatus()).flatMap { $0 }.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
                logger.info("[embedded-runtime] still waiting run=\(self.runID, privacy: .public) seconds=\(polls * 150 / 1000) fileRun=\(status?.runID ?? "none", privacy: .public) fileStatus=\(status?.status ?? "none", privacy: .public)")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        logger.error("[embedded-runtime] readiness timeout run=\(self.runID, privacy: .public)")
        throw Failure.timedOut
    }

    #if os(iOS)
    convenience init(supportDirectory: URL, gatewayPort: UInt16) {
        let runID = UUID().uuidString
        let state = supportDirectory.appendingPathComponent("Operator/openclaw", isDirectory: true)
        let status = state.appendingPathComponent("native-runtime-status.json")
        self.init(runID: runID, gatewayPort: gatewayPort, launch: { token in
            guard let resource = Bundle.main.resourceURL?.appendingPathComponent("runtime/entry.mjs"),
                  FileManager.default.fileExists(atPath: resource.path) else { throw Failure.unavailable }
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            guard EmbeddedNodeBridge.start(entry: resource.path, state: state.path, runID: runID,
                                           token: token, statusPath: status.path, gatewayPort: gatewayPort) else { throw Failure.unavailable }
        }, readStatus: {
            guard FileManager.default.fileExists(atPath: status.path) else { return nil }
            return try Data(contentsOf: status)
        })
    }
    #endif
}
