import Foundation

/// Keeps what the last check found, and when Operator's record action last
/// ran for a check. The action runs in the background, so both sides meet here.
protocol ShortcutCheckStore: Sendable {
    func loadStatus(of shortcut: MessageShortcut) -> ShortcutInstallStatus
    func saveStatus(_ status: ShortcutInstallStatus, of shortcut: MessageShortcut)
    func recordActionLastRan() -> Date?
    func noteRecordActionRan(at date: Date)
}

struct UserDefaultsShortcutCheckStore: ShortcutCheckStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let ranKey = "app.operator.shortcutCheck.recordActionRanAt"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadStatus(of shortcut: MessageShortcut) -> ShortcutInstallStatus {
        guard let data = self.defaults.data(forKey: Self.statusKey(shortcut)),
              let status = try? JSONDecoder().decode(ShortcutInstallStatus.self, from: data)
        else { return .notChecked }
        return status
    }

    func saveStatus(_ status: ShortcutInstallStatus, of shortcut: MessageShortcut) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        self.defaults.set(data, forKey: Self.statusKey(shortcut))
    }

    func recordActionLastRan() -> Date? { self.defaults.object(forKey: Self.ranKey) as? Date }
    func noteRecordActionRan(at date: Date) { self.defaults.set(date, forKey: Self.ranKey) }

    private static func statusKey(_ shortcut: MessageShortcut) -> String {
        "app.operator.shortcutCheck.status.\(shortcut.rawValue)"
    }
}
