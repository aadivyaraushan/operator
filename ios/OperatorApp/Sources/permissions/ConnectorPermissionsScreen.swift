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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(self.mode == .onboarding
                        ? "Operator starts with no access to anything on this iPhone. Turn on only what you want it to reach. Nothing is selected yet, and you can allow anything later from Settings, or when Operator asks in chat."
                        : "What Operator may reach on this iPhone. Changes apply immediately.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                Section("On this iPhone") {
                    ForEach(ConnectorCatalog.all.filter { !$0.requiresAccount }) { descriptor in
                        ConnectorRow(descriptor: descriptor, center: self.center, status: nil)
                    }
                }
                Section("Accounts") {
                    ForEach(ConnectorCatalog.all.filter(\.requiresAccount)) { descriptor in
                        ConnectorRow(descriptor: descriptor, center: self.center, status: self.accountStatus(descriptor.id))
                    }
                }
                if self.mode == .settings {
                    Section("This session") {
                        if self.center.activity.isEmpty {
                            Text("Operator has not read or done anything yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(self.center.activity.prefix(50)) { record in
                                ActivityRow(record: record)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.large)
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
                if let id = self.center.acknowledgementRequired,
                   let acknowledgement = ConnectorCatalog.descriptor(id).writeAcknowledgement
                {
                    ConnectorRiskAcknowledgementSheet(
                        acknowledgement: acknowledgement,
                        onAccept: { self.center.acceptAcknowledgement() },
                        onDecline: { self.center.declineAcknowledgement() })
                }
            }
        }
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
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text(self.acknowledgement.title)
                            .font(.title2.weight(.bold))
                    }
                    ForEach(Array(self.acknowledgement.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                    }
                    Divider()
                    Text("Before this turns on, confirm each of these:")
                        .font(.headline)
                    ForEach(Array(self.acknowledgement.statements.enumerated()), id: \.offset) { index, statement in
                        Toggle(isOn: self.$accepted[index]) {
                            Text(statement).font(.callout)
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("acknowledgement-statement-\(index)")
                    }
                    Button(role: .destructive, action: self.onAccept) {
                        Text(self.acknowledgement.confirmLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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

    private var readGranted: Bool { self.center.isGranted(self.descriptor.id, .read) }
    private var writeGranted: Bool { self.center.isGranted(self.descriptor.id, .write) }
    private var writeBlockedByReadOnly: Bool { self.center.grants.readOnly && self.descriptor.hasWrites }
    private var systemState: SystemPermissionState? { self.descriptor.systemPermission.map(SystemPermissionStatus.current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(self.descriptor.title).font(.headline)
                Spacer()
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if let readSummary = self.descriptor.readSummary {
                Toggle(isOn: Binding(
                    get: { self.readGranted },
                    set: { self.center.set(self.descriptor.id, .read, allowed: $0) }))
                {
                    self.label("Read", readSummary)
                }
                .accessibilityIdentifier("permission-\(self.descriptor.id.rawValue)-read")
            }
            if let writeSummary = self.descriptor.writeSummary {
                Toggle(isOn: Binding(
                    get: { self.writeGranted && !self.center.grants.readOnly },
                    set: { self.center.requestGrant(self.descriptor.id, .write, allowed: $0) }))
                {
                    self.label(self.writeBlockedByReadOnly ? "Act - blocked by Read-only" : "Act", writeSummary)
                }
                // A write needs its read where the connector has one; turning
                // the write on grants the read too, so only Read-only disables.
                .disabled(self.center.grants.readOnly)
                .accessibilityIdentifier("permission-\(self.descriptor.id.rawValue)-write")
            }
            if let setup = self.descriptor.setupInstructions {
                VStack(alignment: .leading, spacing: 6) {
                    Text(setup)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        if self.descriptor.id == .messagesAutosend {
                            Link("Install shortcut", destination: ForegroundMessageSendService.installURL)
                                .font(.caption.weight(.semibold))
                                .accessibilityIdentifier("permission-\(self.descriptor.id.rawValue)-install")
                        }
                        if let url = URL(string: "shortcuts://") {
                            Link("Open Shortcuts", destination: url).font(.caption)
                        }
                    }
                }
            }
            if let systemState {
                HStack(spacing: 8) {
                    Image(systemName: systemState == .denied ? "exclamationmark.triangle" : "iphone")
                        .foregroundStyle(systemState == .denied ? Color.orange : Color.secondary)
                    Text(systemState.label)
                    if systemState == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                        Spacer()
                        Link("Open iOS Settings", destination: url)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func label(_ title: String, _ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(summary).font(.footnote).foregroundStyle(.secondary)
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
                Text(self.record.command).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(self.outcomeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(self.record.outcome == .ran ? Color.primary : Color.orange)
                Text(self.record.date, style: .time).font(.caption2).foregroundStyle(.secondary)
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
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Operator wants to \(self.request.access == .read ? "read" : "use") \(self.descriptor.title)")
                        .font(.subheadline.weight(.semibold))
                    Text((self.request.access == .read ? self.descriptor.readSummary : self.descriptor.writeSummary) ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Allow", action: self.onAllow)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("permission-banner-allow")
                Button("Not now", action: self.onDismiss)
                    .buttonStyle(.bordered)
                Spacer()
                Text("Then ask again.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
