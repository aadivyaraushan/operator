import XCTest
@testable import OperatorApp

@MainActor
final class ShortcutInstallCheckerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingIsInstalledUntilACheckPasses() {
        let checker = self.checker(runner: OpeningRunner(opens: true), store: MemoryShortcutCheckStore())
        XCTAssertEqual(checker.status(of: .send), .notChecked)
        XCTAssertEqual(checker.status(of: .record), .notChecked)
    }

    func testSendShortcutThatReportsSuccessIsInstalled() async {
        let (checker, coordinator, runner) = self.parts()
        async let status = checker.check(.send, recordShortcutName: "unused")
        await self.waitUntil { runner.opened != nil }
        coordinator.resolve(.success)

        let result = await status
        XCTAssertEqual(result, .installed(checkedAt: self.now))
        XCTAssertEqual(checker.status(of: .send), .installed(checkedAt: self.now))
    }

    func testTheTestRunNamesNoRecipientSoNothingCanBeSent() async throws {
        let (checker, coordinator, runner) = self.parts()
        async let status = checker.check(.send, recordShortcutName: "unused")
        await self.waitUntil { runner.opened != nil }
        coordinator.resolve(.success)
        _ = await status

        let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(runner.opened), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "name" }?.value, ForegroundMessageSendService.shortcutName)
        let text = try XCTUnwrap(items.first { $0.name == "text" }?.value)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(input["check"] as? Bool, true)
        XCTAssertEqual(input["to"] as? String, "")
        XCTAssertEqual(input["body"] as? String, "")
    }

    func testNoAnswerFromShortcutsMeansNotFound() async {
        let (checker, _, _) = self.parts(timeout: .milliseconds(30))
        let result = await checker.check(.send, recordShortcutName: "unused")
        XCTAssertEqual(result, .notFound)
    }

    /// Seen on the phone 2026-09-19: the installed shortcut runs, and Send
    /// Message then fails because the test names no recipient.
    func testSendShortcutThatFailsForLackOfARecipientIsInstalled() async {
        let (checker, coordinator, runner) = self.parts()
        async let status = checker.check(.send, recordShortcutName: "unused")
        await self.waitUntil { runner.opened != nil }
        coordinator.resolve(.error, message: "Send Message failed because Shortcuts couldn\u{2019}t convert from Text to Contact, Phone Number, or Email Address.")

        let result = await status
        XCTAssertEqual(result, .installed(checkedAt: self.now))
    }

    func testAnErrorNamingTheShortcutIsShownInShortcutsOwnWords() async {
        let (checker, coordinator, runner) = self.parts()
        async let status = checker.check(.send, recordShortcutName: "unused")
        await self.waitUntil { runner.opened != nil }
        coordinator.resolve(.error, message: "The shortcut \u{201C}OperatorSendMessage\u{201D} could not be found.")

        let result = await status
        XCTAssertEqual(result, .problem("The shortcut \u{201C}OperatorSendMessage\u{201D} could not be found."))
    }

    func testRecordShortcutIsInstalledOnlyWhenOperatorsActionRan() async {
        let store = MemoryShortcutCheckStore()
        let (checker, coordinator, runner) = self.parts(store: store)
        async let status = checker.check(.record, recordShortcutName: "My Recorder")
        await self.waitUntil { runner.opened != nil }
        store.noteRecordActionRan(at: self.now)
        coordinator.resolve(.success)

        let result = await status
        XCTAssertEqual(result, .installed(checkedAt: self.now))
        let items = URLComponents(url: runner.opened!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "name" }?.value, "My Recorder")
        XCTAssertEqual(items?.first { $0.name == "text" }?.value, ShortcutCheck.recordMarker)
    }

    /// A shortcut that takes its text from its own message trigger gets no
    /// text when Operator runs it, so an empty run is a check too.
    func testARunWithNoTextCountsAsACheckAndARealTextDoesNot() {
        XCTAssertTrue(ShortcutCheck.isCheckRun(text: nil))
        XCTAssertTrue(ShortcutCheck.isCheckRun(text: "  \n"))
        XCTAssertTrue(ShortcutCheck.isCheckRun(text: " " + ShortcutCheck.recordMarker))
        XCTAssertFalse(ShortcutCheck.isCheckRun(text: "on my way"))
    }

    func testRecordShortcutThatRanWithoutReachingOperatorIsAProblem() async {
        let (checker, coordinator, runner) = self.parts()
        async let status = checker.check(.record, recordShortcutName: "My Recorder")
        await self.waitUntil { runner.opened != nil }
        coordinator.resolve(.success)

        let result = await status
        guard case .problem = result else { return XCTFail("expected a problem, got \(result)") }
    }

    func testAnOldRunOfOperatorsActionDoesNotCount() async {
        let store = MemoryShortcutCheckStore()
        store.noteRecordActionRan(at: self.now.addingTimeInterval(-3600))
        let (checker, _, _) = self.parts(store: store, timeout: .milliseconds(30))
        let result = await checker.check(.record, recordShortcutName: "My Recorder")
        XCTAssertEqual(result, .notFound)
    }

    func testStatusSurvivesARelaunch() async {
        let store = MemoryShortcutCheckStore()
        let (checker, coordinator, runner) = self.parts(store: store)
        async let status = checker.check(.send, recordShortcutName: "unused")
        await self.waitUntil { runner.opened != nil }
        coordinator.resolve(.success)
        _ = await status

        let relaunched = self.checker(runner: OpeningRunner(opens: true), store: store)
        XCTAssertEqual(relaunched.status(of: .send), .installed(checkedAt: self.now))
    }

    func testIsCheckingOnlyWhileARunIsOut() async {
        let (checker, coordinator, runner) = self.parts()
        XCTAssertFalse(checker.isChecking)
        async let status = checker.check(.send, recordShortcutName: "unused")
        await self.waitUntil { runner.opened != nil }
        XCTAssertTrue(checker.isChecking)
        coordinator.resolve(.cancel)
        _ = await status
        XCTAssertFalse(checker.isChecking)
    }

    // MARK: helpers

    private func parts(
        store: MemoryShortcutCheckStore = MemoryShortcutCheckStore(),
        timeout: Duration = .seconds(5)
    ) -> (ShortcutInstallChecker, ShortcutSendCoordinator, OpeningRunner) {
        let runner = OpeningRunner(opens: true)
        let coordinator = ShortcutSendCoordinator(runner: runner)
        let now = self.now
        return (ShortcutInstallChecker(coordinator: coordinator, store: store, timeout: timeout, now: { now }), coordinator, runner)
    }

    private func checker(runner: OpeningRunner, store: MemoryShortcutCheckStore) -> ShortcutInstallChecker {
        let now = self.now
        return ShortcutInstallChecker(coordinator: ShortcutSendCoordinator(runner: runner), store: store, timeout: .seconds(5), now: { now })
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { await Task.yield() }
    }
}

@MainActor
private final class OpeningRunner: ShortcutRunner {
    let opens: Bool
    private(set) var opened: URL?
    init(opens: Bool) { self.opens = opens }
    func run(_ url: URL) async -> Bool {
        self.opened = url
        return self.opens
    }
}

private final class MemoryShortcutCheckStore: ShortcutCheckStore, @unchecked Sendable {
    private var statuses: [MessageShortcut: ShortcutInstallStatus] = [:]
    private var ranAt: Date?
    func loadStatus(of shortcut: MessageShortcut) -> ShortcutInstallStatus { self.statuses[shortcut] ?? .notChecked }
    func saveStatus(_ status: ShortcutInstallStatus, of shortcut: MessageShortcut) { self.statuses[shortcut] = status }
    func recordActionLastRan() -> Date? { self.ranAt }
    func noteRecordActionRan(at date: Date) { self.ranAt = date }
}
