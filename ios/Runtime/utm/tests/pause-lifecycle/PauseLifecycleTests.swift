import Foundation
private struct TestLogger { func info(_ message: String) {}; func error(_ message: String) {} }
private let logger = TestLogger()
// INSERT_ERRORS
private struct OperatorLaunchCredentials {}
private struct ProtectedLaunchFiles {
    struct URLs {}
    let urls = URLs()
    init(credentials: OperatorLaunchCredentials) throws {}
    func delete() {}
}
@MainActor private enum Trace { static var events: [String] = [] }
@MainActor private final class UTMRegistry {
    static let shared = UTMRegistry()
    func sync() { Trace.events.append("sync") }
}
private enum Failure: Error { case simulated }
@MainActor private final class FakeVM {
    enum State { case started, paused, stopped }
    final class Entry { var isSuspended = false }
    final class QEMU { var additionalArguments: [String] = [] }
    final class Config { let qemu = QEMU() }
    var state: State = .started
    let config = Config()
    let registryEntry = Entry()
    var failure: String?
    func pause() async throws {
        Trace.events.append("pause")
        if failure == "pause" { state = .stopped; throw Failure.simulated }
        state = .paused
    }
    func saveSnapshot(name: String?) async throws {
        Trace.events.append("save")
        if failure == "save" { throw Failure.simulated }
        registryEntry.isSuspended = true
    }
    func resume() async throws {
        Trace.events.append("resume")
        if failure == "resume" { state = .stopped; throw Failure.simulated }
        state = .started
        registryEntry.isSuspended = false
    }
    func start(options: [String]) async throws {
        Trace.events.append("start")
        state = .started
    }
}
@MainActor private final class Adapter {
    enum State: Equatable { case running, saving, suspended, starting, failed(String) }
    var state: State = .running
    var virtualMachine: FakeVM?
    private var hasUncertainGuestState = false
    init(_ vm: FakeVM) { virtualMachine = vm }
    private static func makeFwCfgArguments(fileURLs: ProtectedLaunchFiles.URLs) -> [String] { [] }
// INSERT_METHODS
}
@main private struct PauseLifecycleTests {
    @MainActor static func main() async throws {
        var count = 0
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            count += 1
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(name)")
        }
        let vm = FakeVM()
        let adapter = Adapter(vm)
        Trace.events = []
        let saved = await adapter.saveSnapshot()
        check(saved && Trace.events == ["pause", "save", "sync"] && vm.state == .paused
              && adapter.state == .suspended, "background pauses before save, persists registry, and remains suspended")
        vm.state = .paused
        Trace.events = []
        let resumed = await adapter.start(credentials: .init())
        check(resumed && Trace.events == ["resume", "sync"] && vm.state == .started
              && adapter.state == .running, "foreground resumes paused guest without a second start")
        let cold = FakeVM()
        cold.state = .stopped
        Trace.events = []
        let started = await Adapter(cold).start(credentials: .init())
        check(started && Trace.events == ["start", "sync"], "cold stopped guest still starts")
        for failure in ["pause", "save", "resume"] {
            let brokenVM = FakeVM()
            brokenVM.failure = failure
            if failure == "resume" { brokenVM.state = .paused }
            let broken = Adapter(brokenVM)
            Trace.events = []
            let result: Bool
            if failure == "resume" { result = await broken.start(credentials: .init()) }
            else { result = await broken.saveSnapshot() }
            let failedState: Bool
            if case .failed = broken.state { failedState = true } else { failedState = false }
            check(!result && failedState && !Trace.events.contains("sync"), "\(failure) error cannot report success")
            // A UTM error can claim stopped while guest threads still exist.
            brokenVM.state = .stopped
            brokenVM.failure = nil
            Trace.events = []
            let retry = await broken.start(credentials: .init())
            check(!retry && !Trace.events.contains("start"), "\(failure) uncertainty prevents unsafe replacement guest")
        }
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let saveGuard = source.range(of: "guard await self.vm.saveSnapshot()")!
        let afterSave = source[saveGuard.lowerBound...]
        let nextMethod = afterSave.range(of: "\n    }")!
        let backgroundTail = afterSave[..<nextMethod.upperBound]
        check(!backgroundTail.contains("vm.stop("), "background coordinator does not destroy the saved guest")
        print("Pause lifecycle: \(count - failures)/\(count) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
