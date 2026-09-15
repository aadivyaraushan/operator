import SwiftUI

struct WhatsAppLinkSheet: View {
    @ObservedObject var model: WhatsAppLinkFlowModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                self.content
                    .frame(maxWidth: 440)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Connect WhatsApp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task { await self.model.cancel() }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .task(id: self.scenePhase) {
            await self.model.setForegroundActive(self.scenePhase == .active)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch self.model.state {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "message.badge")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Link your phone")
                    .font(.title2.weight(.semibold))
                Text("Enter the phone number you use with WhatsApp. The temporary link code stays only on this phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone number")
                        .font(.subheadline)
                    TextField("", text: self.$phone)
                        .accessibilityLabel("Phone number")
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .textFieldStyle(.roundedBorder)
                    Text(self.model.phoneError ?? "Include + and country code. Spaces and dashes are welcome.")
                        .font(.caption)
                        .foregroundStyle(self.model.phoneError == nil ? Color.secondary : Color.red)
                        .accessibilityIdentifier("whatsapp-phone-guidance")
                }
                Button("Get link code") {
                    Task { await self.model.start(phone: self.phone) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .starting:
            ProgressView("Requesting a link code…")
        case .waitingForCode:
            VStack(spacing: 16) {
                ProgressView()
                Text("Waiting for a link code…")
                    .font(.title3.weight(.semibold))
                Text("You can switch to WhatsApp. Return here to refresh the link status.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .codeReady:
            VStack(spacing: 16) {
                Image(systemName: "key.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Enter this code in WhatsApp")
                    .font(.title2.weight(.semibold))
                if let code = self.model.pairCode {
                    Text(code)
                        .font(.title.monospaced().weight(.semibold))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ProgressView("Refreshing link code…")
                }
                Text("The code is hidden while this app is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .finishing:
            ProgressView("Finishing WhatsApp link…")
        case .cancelled:
            self.terminalContent(title: "WhatsApp link cancelled", symbol: "xmark.circle")
        case .failed:
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("WhatsApp link could not continue")
                    .font(.title2.weight(.semibold))
                if let message = self.model.failureMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Try again") {
                    Task { await self.model.retry(phone: self.phone) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .linked:
            self.terminalContent(title: "WhatsApp is linked", symbol: "checkmark.circle.fill")
        }
    }

    private func terminalContent(title: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(symbol == "checkmark.circle.fill" ? .green : .secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Button("Done", action: self.model.dismissTerminalState)
                .buttonStyle(.borderedProminent)
        }
    }
}
