import Foundation
@MainActor private enum Trace { static var events: [String] = [] }
private struct Log { func info(_ text: String) {} }
private let logger = Log()
private enum OperatorRuntimeCoordinatorError: Error { case vm(String) }
@MainActor private final class Chat {
    func runtimeIsStarting() { Trace.events.append("gate.closed") }
    func setForegroundActive(_ active: Bool) { Trace.events.append("foreground") }
    func runtimeBecameReady() { Trace.events.append("gate.open") }
    func restoreAndWaitForGatewayReady() async -> Bool { Trace.events.append("chat.connect"); return true }
}
@MainActor private final class VM {
    var succeeds = true
    var paused = false
    let statusText = "test failure"
    func prepareBundledGuest() -> Bool { true }
    func start(credentials: String) async -> Bool {
        Trace.events.append(paused ? "vm.resume" : "vm.start")
        try? await Task.sleep(for: .milliseconds(20))
        Trace.events.append(succeeds ? "vm.ready" : "vm.failed")
        return succeeds
    }
}
@MainActor private final class Node { func start() async { Trace.events.append("node.start") } }
@MainActor private final class Setup { func check() async {} }
private struct Lifecycle {
    enum Event { case becameActive, started }
    enum Action { case start, restoreSnapshot }
    func handle(_ event: Event) -> [Action] { [.start] }
}
@MainActor private final class Coordinator {
    let chat = Chat(), vm = VM(), locationNode = Node(), setup = Setup()
    let lifecycle = Lifecycle()
    func launchCredentials() async throws -> String { "test" }
    func failRuntime(_ message: String) { Trace.events.append("runtime.failed") }
// METHOD
}
@main private struct Tests {
    @MainActor static func main() async {
        var failures = 0
        for paused in [false, true] {
            Trace.events = []
            let coordinator = Coordinator()
            coordinator.vm.paused = paused
            await coordinator.exercise()
            let passed = Trace.events == ["gate.closed", "foreground", paused ? "vm.resume" : "vm.start", "vm.ready", "gate.open", "chat.connect", "node.start"]
            print("\(passed ? "PASS" : "FAIL"): \(paused ? "resume" : "cold start") waits for VM before opening chat")
            if !passed { failures += 1 }
        }
        Trace.events = []
        let failed = Coordinator()
        failed.vm.succeeds = false
        await failed.exercise()
        let passed = Trace.events.contains("runtime.failed") && !Trace.events.contains("gate.open") && !Trace.events.contains("chat.connect")
        print("\(passed ? "PASS" : "FAIL"): failed VM start never opens chat")
        if !passed { failures += 1 }
        exit(failures == 0 ? 0 : 1)
    }
}
