import OperatorCore
import SwiftUI
import UIKit

/// The one place the owner sees and changes what Operator may do. Shown once
/// at first launch with nothing selected, and from the header menu any time.
struct ConnectorPermissionsScreen: View {
    enum Mode { case onboarding, settings }

    @ObservedObject var center: ConnectorPermissionCenter
    let mode: Mode
    /// "Signed in" / "Not signed in" for connectors that need an account; nil otherwise.
    let accountStatus: (ConnectorID) -> String?
    let onDone: () -> Void
    @State private var query = ""

    private var isSearching: Bool {
        !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var found: [ConnectorDescriptor] {
        ConnectorSearch.matches(in: ConnectorCatalog.all.filter { $0.id != .messagesAutosend }, query: self.query)
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                Section {
                    ConnectorSearchField(query: self.$query)
                }
                .listRowSeparator(.hidden)
                if self.isSearching {
                    Section {
                        if self.found.isEmpty {
                            Text("Nothing called \u{201C}\(self.query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}.")
                                .font(OperatorLettering.font(.subheadline))
                                .foregroundStyle(OperatorBrand.muted)
                        }
                        ForEach(self.found) { descriptor in
                            ConnectorRow(
                                descriptor: descriptor, center: self.center,
                                status: descriptor.requiresAccount ? self.accountStatus(descriptor.id) : nil)
                        }
                    }
                } else {
                Section {
                    Text(self.mode == .onboarding
                        ? "Operator starts with no access to anything on this iPhone. Turn on only what you want it to reach. Nothing is selected yet, and you can allow anything later from Settings, or when Operator asks in chat."
                        : "What Operator may reach on this iPhone. Changes apply immediately.")
                        .font(OperatorLettering.font(.subheadline))
                        .foregroundStyle(OperatorBrand.muted)
                }
                Section {
                    Toggle(isOn: Binding(
                        get: { self.center.grants.readOnly },
                        set: { self.center.setReadOnly($0) }))
                    {
                        Text("Read-only")
                    }
                } footer: {
                    Text("Blocks every action below - sending, opening, creating - even where it is allowed. Reading is unaffected.")
                }
                Section {
                    ForEach(ConnectorCatalog.all.filter { !$0.requiresAccount && $0.id != .messagesAutosend }) { descriptor in
                        ConnectorRow(descriptor: descriptor, center: self.center, status: nil)
                    }
                } header: { SectionKicker("On this iPhone") }
                Section {
                    ForEach(ConnectorCatalog.all.filter(\.requiresAccount)) { descriptor in
                        ConnectorRow(descriptor: descriptor, center: self.center, status: self.accountStatus(descriptor.id))
                    }
                } header: { SectionKicker("Accounts") }
                if self.mode == .settings {
                    Section {
                        if self.center.activity.isEmpty {
                            Text("Operator has not read or done anything yet.")
                                .font(OperatorLettering.font(.footnote))
                                .foregroundStyle(OperatorBrand.muted)
                        } else {
                            ForEach(self.center.activity.prefix(50)) { record in
                                ActivityRow(record: record)
                            }
                        }
                    } header: { SectionKicker("This session") }
                }
                }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .listRowSeparatorTint(OperatorBrand.fillStrong)
            .scrollContentBackground(.hidden)
            .background(OperatorBrand.nearBlack)
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(OperatorBrand.nearBlack, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(self.mode == .onboarding ? "Continue" : "Done") { self.onDone() }
                        .accessibilityIdentifier("permissions-done")
                }
            }
            .interactiveDismissDisabled(self.mode == .onboarding)
            .sheet(isPresented: Binding(
                get: { self.center.acknowledgementRequired != nil },
                set: { if !$0 { self.center.declineAcknowledgement() } }))
            {
                if let acknowledgement = self.center.acknowledgementRequired?.acknowledgement {
                    ConnectorRiskAcknowledgementSheet(
                        acknowledgement: acknowledgement,
                        onAccept: { self.center.acceptAcknowledgement() },
                        onDecline: { self.center.declineAcknowledgement() })
                }
            }
        }
    }
}

/// The search field at the top of the page, in the composer's shape.
private struct ConnectorSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(OperatorBrand.dim)
                .keepsShape()
            TextField("Search apps", text: self.$query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("permissions-search")
            if !self.query.isEmpty {
                Button { self.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(OperatorBrand.dim)
                        .keepsShape()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(OperatorBrand.fill, in: Capsule())
    }
}

/// A section's name, small and spaced, the way the chat screen marks a day.
private struct SectionKicker: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(self.title.uppercased())
            .font(OperatorLettering.font(.caption2))
            .kerning(1.3)
            .foregroundStyle(OperatorBrand.dim)
            .padding(.top, 10)
    }
}

/// The warning the owner has to read to the end and accept statement by
/// statement. The confirm button sits below the last statement and is disabled
/// until every one is on, so there is no way through without scrolling past
/// the whole thing. Presented every time; nothing is remembered.
struct ConnectorRiskAcknowledgementSheet: View {
    let acknowledgement: ConnectorAcknowledgement
    let onAccept: () -> Void
    let onDecline: () -> Void
    @State private var accepted: [Bool]

    init(acknowledgement: ConnectorAcknowledgement, onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.acknowledgement = acknowledgement
        self.onAccept = onAccept
        self.onDecline = onDecline
        self._accepted = State(initialValue: Array(repeating: false, count: acknowledgement.statements.count))
    }

    private var allAccepted: Bool { self.accepted.allSatisfy { $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(OperatorLettering.font(.largeTitle, .bold))
                            .foregroundStyle(OperatorBrand.vermilion)
                        Text(self.acknowledgement.title)
                            .font(OperatorLettering.font(.title2, .bold))
                    }
                    ForEach(Array(self.acknowledgement.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(OperatorLettering.font(.body))
                    }
                    Divider()
                    Text("Before this turns on, confirm each of these:")
                        .font(OperatorLettering.font(.headline, .bold))
                    ForEach(Array(self.acknowledgement.statements.enumerated()), id: \.offset) { index, statement in
                        Toggle(isOn: self.$accepted[index]) {
                            Text(statement).font(OperatorLettering.font(.callout))
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("acknowledgement-statement-\(index)")
                    }
                    Button(role: .destructive, action: self.onAccept) {
                        Text(self.acknowledgement.confirmLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OperatorPrimaryButtonStyle())
                    .disabled(!self.allAccepted)
                    .accessibilityIdentifier("acknowledgement-confirm")
                    .padding(.top, 8)
                    Button("Leave it off", action: self.onDecline)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: self.onDecline)
                }
            }
            .interactiveDismissDisabled()
        }
    }
}

private struct ConnectorRow: View {
    let descriptor: ConnectorDescriptor
    @ObservedObject var center: ConnectorPermissionCenter
    let status: String?
    @Environment(\.openURL) private var openURL

    private var readGranted: Bool { self.center.isGranted(self.descriptor.id, .read) }
    private var writeGranted: Bool { self.center.isGranted(self.descriptor.id, .write) }
    private var writeBlockedByReadOnly: Bool { self.center.grants.readOnly && self.descriptor.hasWrites }
    private var systemState: SystemPermissionState? { self.descriptor.systemPermission.map(SystemPermissionStatus.current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(self.descriptor.title).font(OperatorLettering.font(.subheadline, .medium))
                Spacer()
                if let status { Text(status).font(OperatorLettering.font(.caption)).foregroundStyle(OperatorBrand.muted) }
            }
            if let readSummary = self.descriptor.readSummary {
                // Through requestGrant, not set: a read that carries a warning
                // (Discord) must show it first, like a warned write.
                Toggle(isOn: Binding(
                    get: { self.readGranted },
                    set: { self.center.requestGrant(self.descriptor.id, .read, allowed: $0) }))
                {
                    self.label("Read", readSummary)
                }
                .accessibilityIdentifier("permission-\(self.descriptor.id.rawValue)-read")
                if self.descriptor.id == .messages {
                    self.setupSection
                    Divider().padding(.vertical, 4)
                }
            }
            if let writeSummary = self.descriptor.writeSummary {
                Toggle(isOn: Binding(
                    get: { self.writeGranted && !self.center.grants.readOnly },
                    set: {
                        self.center.requestGrant(self.descriptor.id, .write, allowed: $0)
                        // Sending for you lives under Messages > Act, so it goes off with it.
                        if self.descriptor.id == .messages, !$0 { self.center.set(.messagesAutosend, .write, allowed: false) }
                    }))
                {
                    self.label(self.writeBlockedByReadOnly ? "Act - blocked by Read-only" : "Act", writeSummary)
                }
                // A write needs its read where the connector has one; turning
                // the write on grants the read too, so only Read-only disables.
                .disabled(self.center.grants.readOnly)
                .accessibilityIdentifier("permission-\(self.descriptor.id.rawValue)-write")
                if self.descriptor.id == .messages, self.writeGranted, !self.center.grants.readOnly {
                    MessageWriteModePicker(center: self.center)
                }
            }
            if self.descriptor.id != .messages {
                self.setupSection
            }
            if let systemState {
                HStack(spacing: 8) {
                    Image(systemName: systemState == .denied ? "exclamationmark.triangle" : "iphone")
                        .foregroundStyle(systemState == .denied ? OperatorBrand.vermilion : OperatorBrand.muted)
                    Text(systemState.label)
                    if systemState == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                        Spacer()
                        Link("Open iOS Settings", destination: url)
                    }
                }
                .font(OperatorLettering.font(.caption))
                .foregroundStyle(OperatorBrand.muted)
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var setupSection: some View {
        if let setup = self.descriptor.setupInstructions {
            VStack(alignment: .leading, spacing: 6) {
                Text(setup)
                    .font(OperatorLettering.font(.caption))
                    .foregroundStyle(OperatorBrand.muted)
                if self.descriptor.id == .messages {
                    MessagesAutomationPrompt()
                    if RecordIncomingMessageIntent.installURL == nil {
                        Text(RecordIncomingMessageIntent.buildByHandSteps)
                            .font(OperatorLettering.font(.caption))
                            .foregroundStyle(OperatorBrand.muted)
                    }
                    ShortcutInstallStatusRow(shortcut: .record)
                    MessagesReadSetupStatus(readGranted: self.readGranted)
                }
                HStack(spacing: 16) {
                    if self.descriptor.id == .messages {
                        if let install = RecordIncomingMessageIntent.installURL {
                            Link("Install shortcut", destination: install)
                                .font(OperatorLettering.font(.caption, .medium))
                                .accessibilityIdentifier("permission-messages-install")
                        }
                        if #available(iOS 27, *) {
                            // iOS 27 adds triggers in the shortcut editor.
                        } else {
                            Link("Create automation", destination: RecordIncomingMessageIntent.createAutomationURL)
                                .font(OperatorLettering.font(.caption, .medium))
                                .accessibilityIdentifier("permission-messages-automation")
                        }
                    }
                    if let url = URL(string: "shortcuts://") {
                        Link("Open Shortcuts", destination: url).font(OperatorLettering.font(.caption))
                    }
                }
            }
        }
    }

    private func label(_ title: String, _ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(summary).font(OperatorLettering.font(.footnote)).foregroundStyle(OperatorBrand.muted)
        }
    }
}

private struct ActivityRow: View {
    let record: ConnectorActivityRecord

    private var outcomeLabel: String {
        switch self.record.outcome {
        case .ran: "Ran"
        case .denied: "Refused"
        case .failed: "Failed"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ConnectorCatalog.descriptor(self.record.connector).title) - \(self.record.access == .read ? "read" : "act")")
                Text(self.record.command).font(OperatorLettering.font(.caption2)).foregroundStyle(OperatorBrand.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(self.outcomeLabel)
                    .font(OperatorLettering.font(.caption, .medium))
                    .foregroundStyle(self.record.outcome == .ran ? OperatorBrand.light : OperatorBrand.vermilion)
                Text(self.record.date, style: .time).font(OperatorLettering.font(.caption2)).foregroundStyle(OperatorBrand.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown in chat when the agent asked for something the owner has not
/// allowed - the ask, in context, instead of a refusal after the fact.
struct PermissionRequestBanner: View {
    let request: ConnectorGrantRequest
    let onAllow: () -> Void
    let onDismiss: () -> Void

    private var descriptor: ConnectorDescriptor { ConnectorCatalog.descriptor(self.request.connector) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised")
                    .font(OperatorLettering.font(.title3, .bold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Operator wants to \(self.request.access == .read ? "read" : "use") \(self.descriptor.title)")
                        .font(OperatorLettering.font(.subheadline, .medium))
                    Text((self.request.access == .read ? self.descriptor.readSummary : self.descriptor.writeSummary) ?? "")
                        .font(OperatorLettering.font(.footnote))
                        .foregroundStyle(OperatorBrand.muted)
                }
            }
            HStack {
                Button("Allow", action: self.onAllow)
                    .buttonStyle(OperatorPrimaryButtonStyle())
                    .accessibilityIdentifier("permission-banner-allow")
                Button("Not now", action: self.onDismiss)
                    .buttonStyle(OperatorQuietButtonStyle())
                Spacer()
                Text("Then ask again.").font(OperatorLettering.font(.caption)).foregroundStyle(OperatorBrand.muted)
            }
        }
        .padding(12)
        .background(OperatorBrand.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct MessagesReadSetupStatus: View {
    @EnvironmentObject private var model: MessagesReadSetupModel
    @Environment(\.scenePhase) private var scenePhase
    let readGranted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Check setup") { self.model.refresh() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("permission-messages-check")
            if !self.readGranted {
                Text("Turn on Read so Operator can summarise your texts.")
            }
            if let last = self.model.lastReceived {
                Label("Automation received a text", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(OperatorBrand.vermilion)
                Text("\(last.sender.isEmpty ? "Unknown sender" : last.sender): \(String(last.text.prefix(120)))")
                    .lineLimit(3)
                Text("Last received \(last.receivedAt, style: .relative) ago · \(self.model.recordedCount) received texts saved")
                    .foregroundStyle(OperatorBrand.muted)
            } else {
                Text("No texts recorded yet. Send yourself a text with two words, then tap Check. If it still does not appear, check Run Immediately and the shortcut selected in Shortcuts.")
            }
        }
        .font(OperatorLettering.font(.caption))
        .accessibilityIdentifier("permission-messages-setup-status")
        .onAppear { self.model.refresh() }
        .onChange(of: self.scenePhase) { _, phase in
            if phase == .active { self.model.refresh() }
        }
    }
}

private struct MessagesAutomationPrompt: View {
    @AppStorage(ShortcutInstallStatusRow.recordNameKey) private var shortcutName = RecordIncomingMessageIntent.installedShortcutName
    @State private var copied = false

    private var selectedName: String {
        self.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(self.copied ? "Prompt copied" : "Copy setup prompt") {
                UIPasteboard.general.string = RecordIncomingMessageIntent.automationPrompt(shortcutName: self.selectedName)
                self.copied = true
            }
            .buttonStyle(.borderless)
            .disabled(self.selectedName.isEmpty)
            .accessibilityIdentifier("permission-messages-copy-prompt")
            DisclosureGroup("Renamed the installed shortcut?") {
                Text("The name must match the installed shortcut exactly. If you renamed it or installed a duplicate, enter the name shown in Shortcuts before copying the prompt.")
                    .foregroundStyle(OperatorBrand.muted)
                TextField("Installed shortcut name", text: self.$shortcutName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("permission-messages-shortcut-name")
            }
        }
        .font(OperatorLettering.font(.caption))
        .onChange(of: self.shortcutName) { _, _ in self.copied = false }
    }
}
