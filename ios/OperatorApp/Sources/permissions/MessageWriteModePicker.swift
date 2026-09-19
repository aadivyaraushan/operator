import SwiftUI

/// Under Messages > Act: who writes the texts Operator sends. Both choices go
/// out through the send shortcut, so its install status sits here too.
struct MessageWriteModePicker: View {
    @ObservedObject var center: ConnectorPermissionCenter
    @AppStorage(UserDefaultsMessageWriteModeStore.key) private var stored = MessageWriteMode.custom.rawValue
    /// Auto carries a warning; the choice only lands if it is accepted.
    @State private var waitingOnAutoWarning = false

    private var mode: MessageWriteMode { MessageWriteMode(rawValue: self.stored) ?? .custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MessageWriteMode.allCases, id: \.self) { option in
                Button { self.choose(option) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: self.mode == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(self.mode == option ? OperatorBrand.vermilion : OperatorBrand.muted)
                            .keepsShape()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(OperatorLettering.font(.subheadline, .medium))
                            Text(option.summary)
                                .font(OperatorLettering.font(.caption))
                                .foregroundStyle(OperatorBrand.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(self.mode == option ? .isSelected : [])
                .accessibilityIdentifier("permission-messages-mode-\(option.rawValue)")
            }
            ShortcutInstallStatusRow(shortcut: .send)
            Text("Both send through a shortcut you install once. Without it, Operator opens Messages with the text filled in and you tap Send.")
                .font(OperatorLettering.font(.caption))
                .foregroundStyle(OperatorBrand.muted)
            HStack(spacing: 16) {
                Link("Install shortcut", destination: ForegroundMessageSendService.installURL)
                    .font(OperatorLettering.font(.caption, .medium))
                    .accessibilityIdentifier("permission-messagesAutosend-install")
                if let url = URL(string: "shortcuts://") {
                    Link("Open Shortcuts", destination: url).font(OperatorLettering.font(.caption))
                }
            }
        }
        .padding(.leading, 4)
        .onAppear { self.syncGrant() }
        .onChange(of: self.center.acknowledgementRequired) { _, pending in
            guard self.waitingOnAutoWarning, pending == nil else { return }
            self.waitingOnAutoWarning = false
            if self.center.isGranted(.messagesAutosend, .write) {
                self.stored = MessageWriteMode.auto.rawValue
            } else {
                // Warning declined: stay on Custom, which needs no warning.
                self.center.set(.messagesAutosend, .write, allowed: true)
            }
        }
    }

    private func choose(_ option: MessageWriteMode) {
        guard option != self.mode else { return }
        switch option {
        case .custom:
            self.stored = option.rawValue
            self.center.set(.messagesAutosend, .write, allowed: true)
        case .auto:
            // Off, then asked for again, so the warning is always shown.
            self.center.set(.messagesAutosend, .write, allowed: false)
            self.waitingOnAutoWarning = true
            self.center.requestGrant(.messagesAutosend, .write, allowed: true)
        }
    }

    /// Custom needs the send route open; the person writes every word, so it
    /// is granted without the warning that Auto carries.
    private func syncGrant() {
        if self.mode == .custom, !self.center.isGranted(.messagesAutosend, .write) {
            self.center.set(.messagesAutosend, .write, allowed: true)
        }
    }
}
