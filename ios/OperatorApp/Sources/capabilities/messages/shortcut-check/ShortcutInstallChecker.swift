import Foundation
import OSLog

/// Proves a shortcut is installed the only way iOS allows: by running it with
/// a harmless input and seeing what comes back. Until a check passes, a
/// shortcut counts as not installed.
@MainActor
final class ShortcutInstallChecker: ObservableObject {
    @Published private(set) var statuses: [MessageShortcut: ShortcutInstallStatus]
    /// The shortcut out on a test run. The app reads `isChecking` so a return
    /// from Shortcuts is not logged as a real send.
    @Published private(set) var checking: MessageShortcut?

    var isChecking: Bool { self.checking != nil }

    private let coordinator: ShortcutSendCoordinator
    private let store: any ShortcutCheckStore
    private let timeout: Duration
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "shortcut-check")

    init(
        coordinator: ShortcutSendCoordinator,
        store: any ShortcutCheckStore,
        timeout: Duration = .seconds(20),
        now: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.store = store
        self.timeout = timeout
        self.now = now
        self.statuses = Dictionary(uniqueKeysWithValues: MessageShortcut.allCases.map { ($0, store.loadStatus(of: $0)) })
    }

    func status(of shortcut: MessageShortcut) -> ShortcutInstallStatus {
        self.statuses[shortcut] ?? .notChecked
    }

    @discardableResult
    func check(_ shortcut: MessageShortcut, recordShortcutName: String) async -> ShortcutInstallStatus {
        guard self.checking == nil,
              let url = ShortcutCheck.testRunURL(for: shortcut, recordShortcutName: recordShortcutName)
        else { return self.status(of: shortcut) }

        let started = self.now()
        self.checking = shortcut
        self.logger.info("[shortcut-check] test run started shortcut=\(shortcut.rawValue, privacy: .public)")
        let completion = await self.coordinator.send(url, timeout: self.timeout)
        self.checking = nil

        let ranAt = self.store.recordActionLastRan()
        let status = ShortcutCheck.status(
            of: shortcut,
            completion: completion,
            recordActionRan: ranAt.map { $0 >= started } ?? false,
            now: self.now())
        self.store.saveStatus(status, of: shortcut)
        self.statuses = self.statuses.merging([shortcut: status]) { _, new in new }
        self.logger.info("[shortcut-check] shortcut=\(shortcut.rawValue, privacy: .public) outcome=\(completion.outcome.rawValue, privacy: .public) message=\(completion.message ?? "none", privacy: .public) status=\(String(describing: status), privacy: .public)")
        return status
    }
}
