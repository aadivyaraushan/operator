import Foundation
@MainActor private enum Trace { static var events: [String] = [] }
private struct Log {func info(_ text: String) {} ; func error(_ text: String) {} }
private let logger = Log()
private enum OperatorRuntimeCoordinatorError: Error { case vm(String), gatewayNotReady }
@MainActor private final class Chat {
    var succeeds = true
    func runtimeIsStarting() {Trace.events.append("starting")}
    func runtimeBecameReady() {Trace.events.append("ready")}
    func restoreAndWaitForGatewayReady() async -> Bool {Trace.events.append("restore");return succeeds}
}
@MainActor private final class Node {
    func stop() async {Trace.events.append("node.stop")}
    func start() async {Trace.events.append("node.start")}
}
@MainActor private final class VM {
    let statusText = "test"
    func stop(force: Bool) async -> Bool {Trace.events.append("vm.stop");return true}
    func start(credentials: String) async -> Bool {Trace.events.append("vm.start");return true}
}
@MainActor private final class Coordinator {
    let chat = Chat(), locationNode = Node(), vm = VM()
    func launchCredentials() async throws -> String {"test"}
// METHOD
}
@main private struct Tests {
    @MainActor static func main() async throws {
        let coordinator = Coordinator()
        try await coordinator.exercise()
        let success = Trace.events == ["starting", "node.stop", "ready", "restore", "node.start"]
        print("\(success ? "PASS" : "FAIL"): reconnects chat/node without VM teardown")
        Trace.events = []
        coordinator.chat.succeeds = false
        var threw = false
        do {try await coordinator.exercise()} catch {threw = true}
        let failure = threw && !Trace.events.contains("node.start") && !Trace.events.contains("vm.stop")
        print("\(failure ? "PASS" : "FAIL"): failed chat reconnect cannot report setup success")
        if !success || !failure {exit(1)}
    }
}
