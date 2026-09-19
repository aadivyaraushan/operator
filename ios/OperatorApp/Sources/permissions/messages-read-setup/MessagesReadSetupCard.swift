import SwiftUI

/// Setting up "read my texts", as two short steps with their state beside
/// them. Step 1's check runs the shortcut and sees whether it reaches
/// Operator; the last text received is shown once there is one.
struct MessagesReadSetupCard: View {
    let readGranted: Bool

    @EnvironmentObject private var model: MessagesReadSetupModel
    @EnvironmentObject private var checker: ShortcutInstallChecker
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ShortcutInstallStatusRow.recordNameKey) private var shortcutName = RecordIncomingMessageIntent.installedShortcutName

    private var trimmedName: String { self.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shortcutStatus: ShortcutInstallStatus { self.checker.status(of: .record) }
    private var isWorking: Bool { self.model.lastReceived != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.step(1, "Add the shortcut", done: self.shortcutStatus.isInstalled || self.isWorking) {
                if let install = RecordIncomingMessageIntent.installURL {
                    Link("Install", destination: install)
                        .accessibilityIdentifier("permission-messages-install")
                }
                self.shortcutCheckButton
            }
            if let note = self.shortcutNote {
                self.note(note)
            }
            Divider().overlay(OperatorBrand.fillStrong)
            self.step(2, self.automationStepTitle, done: self.isWorking) {
                self.automationAction
            }
            if let note = self.automationNote {
                self.note(note)
            }
            self.note(self.receivedNote)
                .accessibilityIdentifier("permission-messages-setup-status")
            DisclosureGroup("Shortcut has another name?") {
                TextField("Name shown in Shortcuts", text: self.$shortcutName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("permission-messages-shortcut-name")
            }
            .foregroundStyle(OperatorBrand.muted)
            .padding(.top, 8)
        }
        .font(OperatorLettering.font(.caption))
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OperatorBrand.fill, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if RecordIncomingMessageIntent.savedNameToKeep(self.shortcutName, bundleID: Bundle.main.bundleIdentifier) == nil {
                self.shortcutName = RecordIncomingMessageIntent.installedShortcutName
            }
            self.model.refresh()
        }
        .onChange(of: self.scenePhase) { _, phase in
            if phase == .active { self.model.refresh() }
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(OperatorBrand.vermilion)
                } else {
                    Text("\(number)").foregroundStyle(OperatorBrand.vermilion)
                }
            }
            .font(OperatorLettering.font(.subheadline, .medium))
            .frame(width: 18)
            .keepsShape()
            Text(title)
                .font(OperatorLettering.font(.subheadline))
            Spacer(minLength: 8)
            HStack(spacing: 14) { actions() }
                .font(OperatorLettering.font(.caption, .medium))
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(OperatorBrand.muted)
            .padding(.leading, 28)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var shortcutCheckButton: some View {
        if self.checker.checking == .record {
            ProgressView().controlSize(.small)
        } else if !self.shortcutStatus.isInstalled {
            Button("Check") {
                Task { await self.checker.check(.record, recordShortcutName: self.trimmedName) }
            }
            .disabled(self.checker.isChecking)
            .accessibilityIdentifier("shortcut-record-check")
        }
    }

    private var shortcutNote: String? {
        switch self.shortcutStatus {
        case .installed: nil
        case .notChecked: RecordIncomingMessageIntent.installURL == nil ? RecordIncomingMessageIntent.buildByHandSteps : nil
        case .notFound: "Shortcuts did not answer. Add the shortcut, then check again."
        case let .problem(message): "Shortcuts said: \(message)"
        }
    }

    private var automationStepTitle: String {
        if #available(iOS 27, *) { "Switch on its Automation" } else { "Create the automation" }
    }

    /// Before iOS 27 a shortcut cannot carry its own trigger, so the person
    /// makes a separate automation that runs it.
    private var automationNote: String? {
        if #available(iOS 27, *) { return nil }
        return "Pick Message, set \"Message contains\" to one space, choose Run Immediately, then run \"\(self.trimmedName)\" with Shortcut Input."
    }

    @ViewBuilder
    private var automationAction: some View {
        if #available(iOS 27, *) {
            if let url = URL(string: "shortcuts://") {
                Link("Open Shortcuts", destination: url)
            }
        } else {
            Link("Create", destination: RecordIncomingMessageIntent.createAutomationURL)
                .accessibilityIdentifier("permission-messages-automation")
        }
    }

    private var receivedNote: String {
        guard let last = self.model.lastReceived else {
            let waiting = "No texts yet. One-word texts are missed. If none arrive, check the automation is still on."
            return self.readGranted ? waiting : "Turn on Read first. " + waiting
        }
        let sender = last.sender.isEmpty ? "Unknown sender" : last.sender
        let when = last.receivedAt.formatted(.relative(presentation: .named))
        return "Working. \(sender), \(when). \(self.model.recordedCount) saved."
    }
}
