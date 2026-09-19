import SwiftUI

/// Whether one of the Messages shortcuts is installed, with the button that
/// finds out. Shows "Not installed" until a test run has proved otherwise.
struct ShortcutInstallStatusRow: View {
    let shortcut: MessageShortcut
    /// Called when a check passes, so the row's owner can ask for the grant
    /// the shortcut exists for.
    var onInstalled: () -> Void = {}

    @EnvironmentObject private var checker: ShortcutInstallChecker
    @AppStorage(ShortcutInstallStatusRow.recordNameKey) private var recordShortcutName = RecordIncomingMessageIntent.installedShortcutName

    static let recordNameKey = "app.operator.messages.recordShortcutName"

    private var status: ShortcutInstallStatus { self.checker.status(of: self.shortcut) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: self.status.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(self.status.isInstalled ? OperatorBrand.vermilion : OperatorBrand.muted)
                    .keepsShape()
                Text(self.title)
                    .font(OperatorLettering.font(.caption, .medium))
                Spacer()
                if self.checker.checking == self.shortcut {
                    ProgressView().controlSize(.small)
                } else {
                    Button(self.status == .notChecked ? "Check" : "Check again") {
                        Task {
                            let name = self.recordShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await self.checker.check(self.shortcut, recordShortcutName: name).isInstalled { self.onInstalled() }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(OperatorLettering.font(.caption, .medium))
                    .disabled(self.checker.isChecking)
                    .accessibilityIdentifier("shortcut-\(self.shortcut.rawValue)-check")
                }
            }
            Text(self.detail)
                .font(OperatorLettering.font(.caption))
                .foregroundStyle(OperatorBrand.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OperatorBrand.fill, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shortcut-\(self.shortcut.rawValue)-status")
    }

    private var title: String {
        switch self.status {
        case .installed: "Shortcut installed"
        case .notChecked, .notFound: "Shortcut not installed"
        case .problem: "Shortcut not working"
        }
    }

    private var detail: String {
        switch self.status {
        case let .installed(checkedAt):
            "Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))."
        case .notChecked:
            "Not confirmed yet. Install it, then tap Check. Shortcuts opens for a moment and comes back; nothing is sent."
        case .notFound:
            "Shortcuts did not answer, which is what a missing shortcut looks like. Install it, then check again."
        case let .problem(message):
            "Shortcuts said: \(message)"
        }
    }
}
