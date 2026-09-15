import OperatorCore
import SwiftUI

private extension ModelSetupState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum ChatMessageText {
    static func accessibilityLabel(for message: ChatMessage) -> String {
        let speaker = message.role == .user ? "You" : "Operator"
        let text: String
        if case let .weather(card) = message.attachment {
            text = "Weather, \(card.condition), \(card.temperatureCelsius) degrees Celsius"
        } else {
            text = String(displayText(for: message).characters)
        }
        var label = "\(speaker), \(text)"
        if message.role == .user, message.delivery != .accepted {
            label += message.delivery == .sending ? ", Sending" : ", Waiting"
        }
        return label
    }

    static func displayText(for message: ChatMessage) -> AttributedString {
        if message.role == .assistant {
            return assistantText(message.text)
        }

        return AttributedString(message.text)
    }

    static func assistantText(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct ChatScreen: View {
    @ObservedObject var model: ChatSessionModel
    @ObservedObject var setup: ModelSetupModel
    @ObservedObject var whatsapp: WhatsAppLinkFlowModel
    @ObservedObject var accounts: NativeAccountSetupCoordinator
    @ObservedObject var notion: NativeNotionSetupCoordinator
    @ObservedObject var youtube: YouTubeAPIKeySetupModel
    @State private var isConnectionsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Header(state: self.model.connectionState)
                Menu {
                    Button("Connect WhatsApp") { self.whatsapp.present() }
                    Button("Connect accounts") { self.isConnectionsPresented = true }
                    if self.notion.state == .needsSetup {
                        Button("Notion setup required") {}
                            .disabled(true)
                    } else {
                        Button("Connect Notion") { self.notion.connect() }
                    }
                } label: {
                    Image(systemName: "link")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Connect services")
                .disabled(self.setup.isPresented)
                .sheet(isPresented: Binding(
                    get: { self.whatsapp.isPresented },
                    set: { if !$0 { self.whatsapp.dismissTerminalState() } })) {
                    WhatsAppLinkSheet(model: self.whatsapp)
                }
                .sheet(isPresented: self.$isConnectionsPresented) {
                    NativeAccountConnectionSheet(model: self.accounts, youtube: self.youtube)
                }
            }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if self.model.messages.isEmpty, self.model.streamingReply == nil {
                            Welcome(setup: self.setup)
                                .frame(maxWidth: .infinity, minHeight: 360)
                            if self.setup.state == .checking || self.setup.state == .unavailable || self.setup.state.isFailed {
                                SetupStatus(setup: self.setup)
                            }
                        } else if self.setup.state == .checking || self.setup.state == .unavailable || self.setup.state.isFailed {
                            SetupStatus(setup: self.setup)
                        }
                        ForEach(self.model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        ForEach(self.model.approvals) { approval in
                            ApprovalCard(approval: approval, model: self.model)
                                .id("approval-\(approval.id)")
                        }
                        if let streamingReply = self.model.streamingReply {
                            StreamingBubble(text: streamingReply)
                                .id("streaming-reply")
                        }
                        if let lastError = self.model.lastError {
                            Text(lastError)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: self.model.messages.count) {
                    if let id = self.model.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onChange(of: self.model.streamingReply) {
                    if self.model.streamingReply != nil {
                        proxy.scrollTo("streaming-reply", anchor: .bottom)
                    }
                }
                .onChange(of: self.model.approvals.map(\.id)) {
                    if let id = self.model.approvals.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("approval-\(id)", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
            if !self.model.messages.isEmpty, self.setup.state == .needsSignIn {
                SetupBanner(setup: self.setup)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            Composer(model: self.model, dictation: self.model.dictation)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            self.model.restore()
            await self.setup.check()
        }
        .sheet(
            isPresented: Binding(
                get: { self.setup.isPresented },
                set: { if !$0 { self.setup.dismiss() } }))
        {
            ModelSetupSheet(model: self.setup)
        }
    }
}

private struct Header: View {
    let state: ConnectionState

    var body: some View {
        HStack {
            Text("Operator")
                .font(.headline)
            Spacer()
            Label(self.state.title, systemImage: self.state.symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(self.state == .offline ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Operator, \(self.state.title)")
    }
}

private struct Welcome: View {
    @ObservedObject var setup: ModelSetupModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("What can I do for you?")
                .font(.title2.weight(.semibold))
            Text("One conversation. Ask for anything.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if self.setup.state == .needsSignIn {
                Button("Connect ChatGPT") {
                    Task { await self.setup.beginChatGPTSignIn() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
    }
}

private struct SetupStatus: View {
    @ObservedObject var setup: ModelSetupModel

    var body: some View {
        VStack(spacing: 12) {
            switch self.setup.state {
            case .checking:
                ProgressView("Checking ChatGPT connection…")
            case .unavailable:
                Text("ChatGPT connection could not be checked.")
                    .foregroundStyle(.secondary)
                Button("Retry account check") {
                    Task { await self.setup.retryAccountCheck() }
                }
                .buttonStyle(.bordered)
            case let .failed(message):
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Retry account check") {
                    Task { await self.setup.retryAccountCheck() }
                }
                .buttonStyle(.bordered)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct SetupBanner: View {
    @ObservedObject var setup: ModelSetupModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(.tint)
            Text("Connect ChatGPT to start asking Operator.")
                .font(.footnote)
            Spacer()
            Button("Connect") {
                Task { await self.setup.beginChatGPTSignIn() }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(10)
        .background(
            Color.accentColor.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: self.message.role == .user ? .trailing : .leading, spacing: 4) {
            if case let .weather(card) = self.message.attachment {
                WeatherResultCard(card: card)
            } else {
                Text(ChatMessageText.displayText(for: self.message))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(self.message.role == .user ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if self.message.role == .user, self.message.delivery != .accepted {
                Text(self.message.delivery == .sending ? "Sending" : "Waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: self.message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ChatMessageText.accessibilityLabel(for: self.message))
    }
}

private struct WeatherResultCard: View {
    let card: WeatherCard
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weather").font(.headline)
            Text(self.card.condition).font(.subheadline)
            Text("\(self.card.temperatureCelsius, format: .number.precision(.fractionLength(0)))°C").font(.title2.weight(.semibold))
            if let apparent = self.card.apparentCelsius { Text("Feels like \(apparent, format: .number.precision(.fractionLength(0)))°C").font(.footnote).foregroundStyle(.secondary) }
            if let high = self.card.highCelsius, let low = self.card.lowCelsius { Text("High \(high, format: .number.precision(.fractionLength(0)))° · Low \(low, format: .number.precision(.fractionLength(0)))°").font(.footnote).foregroundStyle(.secondary) }
            HStack { AsyncImage(url: self.colorScheme == .dark ? self.card.attribution.combinedMarkDarkURL : self.card.attribution.combinedMarkLightURL) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(height: 20).accessibilityLabel("Apple Weather"); Spacer(); Link("Legal", destination: self.card.attribution.legalPageURL).font(.footnote) }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(ChatMessageText.assistantText(self.text))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Operator is working")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ApprovalCard: View {
    let approval: GatewayApprovalSnapshot
    @ObservedObject var model: ChatSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Action needs your approval", systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(self.approval.presentation.title)
                .font(.subheadline.weight(.semibold))
            Text(self.approval.presentation.detail)
                .font(.footnote)
                .textSelection(.enabled)
            if let warning = self.approval.presentation.warning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(self.approval.presentation.allowedDecisions, id: \.self) { decision in
                    if decision == .deny {
                        Button(self.label(for: decision)) {
                            self.model.resolveApproval(id: self.approval.id, decision: decision)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(!self.approval.isActionable())
                    } else {
                        Button(self.label(for: decision)) {
                            self.model.resolveApproval(id: self.approval.id, decision: decision)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .disabled(!self.approval.isActionable())
                    }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Action needs your approval: \(self.approval.presentation.title)")
    }

    private func label(for decision: GatewayApprovalDecision) -> String {
        switch decision {
        case .allowOnce: "Allow once"
        case .allowAlways: "Always allow"
        case .deny: "Deny"
        }
    }
}

private struct Composer: View {
    @ObservedObject var model: ChatSessionModel
    @ObservedObject var dictation: OfflineDictationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Message Operator",
                    text: Binding(
                        get: { self.model.draft },
                        set: { self.model.updateDraft($0) }
                    ),
                    axis: .vertical)
                    .lineLimit(1 ... 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("Message Operator")
                    .accessibilityIdentifier("chat-composer")

                Button(action: self.toggleDictation) {
                    Image(systemName: self.dictation.state == .recording ? "stop.fill" : "mic.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(self.dictation.state == .recording ? .red : .accentColor)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(self.dictation.state == .recording ? "Stop dictation" : "Start offline dictation")
                .accessibilityHint("Adds on-device speech to the editable message draft")

                if self.model.connectionState == .working {
                    Button(action: self.model.stop) {
                        Image(systemName: "stop.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Stop Operator")
                } else {
                    Button(action: self.model.send) {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            if case let .unavailable(message) = self.dictation.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dictation unavailable: \(message)")
            }
        }
    }

    private func toggleDictation() {
        if self.dictation.state == .recording || self.dictation.state == .requestingPermission {
            self.model.stopDictation()
        } else {
            self.model.startDictation()
        }
    }
}
