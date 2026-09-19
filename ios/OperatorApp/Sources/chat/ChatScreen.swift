import OperatorCore
import SwiftUI

private extension ModelSetupState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum ChatMessageText {
    static func accessibilityLabel(for message: ChatMessage, inFlight: Bool = false) -> String {
        let speaker = message.role == .user ? "You" : "Operator"
        let text: String
        if case let .weather(card) = message.attachment {
            text = "Weather, \(card.condition), \(card.temperatureCelsius) degrees Celsius"
        } else {
            text = String(displayText(for: message).characters)
        }
        var label = "\(speaker), \(text)"
        if let state = deliveryLabel(for: message, inFlight: inFlight) {
            label += ", \(state)"
        }
        return label
    }

    /// The word under a person's bubble, or nil once the runtime has the
    /// message. The store says "sending" until the reply is saved, because
    /// the outbox is how a reply survives a dropped connection; the person
    /// only needs to know the message is being worked on.
    static func deliveryLabel(for message: ChatMessage, inFlight: Bool) -> String? {
        guard message.role == .user, !inFlight else { return nil }
        switch message.delivery {
        case .accepted: return nil
        case .sending: return "Sending"
        default: return "Waiting"
        }
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
    @ObservedObject var discord: DiscordAccountSetupModel
    @ObservedObject var canvas: CanvasAccountSetupModel
    let canvasSession: CanvasSessionStore
    @ObservedObject var permissions: ConnectorPermissionCenter
    @EnvironmentObject private var conversations: MessageConversationService
    @State private var isConnectionsPresented = false
    @State private var isPermissionsPresented = false
    /// Whether the transcript follows new content to its end. Set by the
    /// person's own scrolling only: a drag that ends away from the end
    /// stops following, a drag that ends at the end resumes it, and their
    /// own new message always resumes it. Content growing under a still
    /// finger-free view never changes it, which is what made the old
    /// "near the bottom" test fail the moment the reply bubble appeared
    /// below the sent message.
    @State private var isFollowing = true
    @State private var isNearEnd = true
    /// True from the person's touch until the scroll it started comes to
    /// rest; the app's own animated scrolls never set it.
    @State private var isPersonScrolling = false

    /// "Signed in" / "Not signed in" for the Permissions page's account rows.
    private func accountStatus(_ id: ConnectorID) -> String? {
        let provider: OAuthProvider? = switch id {
        case .google, .googleTasks, .youtubeSubscriptions: .google
        case .microsoft, .outlookCalendar: .microsoftOutlook
        case .slack: .slack
        case .spotify: .spotify
        default: nil
        }
        if let provider {
            return self.accounts.state(for: provider) == .connected ? "Signed in" : "Not signed in"
        }
        if id == .notion { return self.notion.state == .connected ? "Signed in" : "Not signed in" }
        if id == .whatsapp { return self.whatsapp.state == .linked ? "Linked" : "Not linked" }
        if id == .discord { return self.discord.isConnected ? "Token saved" : "No token" }
        if id == .canvas { return self.canvas.isConnected ? "Connected" : "Not connected" }
        return nil
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard self.isFollowing else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
        } else {
            proxy.scrollTo("end", anchor: .bottom)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Header(
                    state: self.model.connectionState,
                    mark: OperatorMarkState(
                        isWorking: self.model.connectionState == .working,
                        needsPerson: !self.model.approvals.isEmpty || !self.model.questions.isEmpty))
                Button { self.isPermissionsPresented = true } label: {
                    Image(systemName: "shield")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Permissions")
                .accessibilityIdentifier("open-permissions")
                .disabled(self.setup.isPresented)
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
                    .operatorSheetStyle()
                }
                .sheet(isPresented: self.$isConnectionsPresented) {
                    NativeAccountConnectionSheet(model: self.accounts, youtube: self.youtube, discord: self.discord, canvas: self.canvas, canvasSession: self.canvasSession)
                    .operatorSheetStyle()
                }
                .sheet(isPresented: self.$isPermissionsPresented) {
                    ConnectorPermissionsScreen(
                        center: self.permissions, mode: .settings,
                        accountStatus: self.accountStatus,
                        onDone: { self.isPermissionsPresented = false })
                    .operatorSheetStyle()
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
                            MessageBubble(
                                message: message,
                                steps: self.model.stepsByReply[message.id] ?? [],
                                inFlight: self.model.inFlight.contains(message.id))
                                .id(message.id)
                        }
                        MessageConversationCards(service: self.conversations)
                        ForEach(self.model.answeredQuestions) { answered in
                            AnsweredQuestionLine(answered: answered)
                                .id("answered-\(answered.id)")
                        }
                        ForEach(self.model.questions) { question in
                            QuestionCard(record: question, model: self.model)
                                .id("question-\(question.id)")
                        }
                        if self.model.liveActivity != nil || self.model.streamingReply != nil {
                            ActivityBubble(
                                activity: self.model.liveActivity ?? ChatLiveActivity(phase: .writing),
                                text: self.model.streamingReply)
                                .id("streaming-reply")
                        }
                        if let lastError = self.model.lastError {
                            Text(lastError)
                                .font(OperatorLettering.font(.footnote))
                                .foregroundStyle(OperatorBrand.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                        // The end of the transcript, whatever is last.
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                } action: { _, nearEnd in
                    self.isNearEnd = nearEnd
                }
                .onScrollPhaseChange { _, phase in
                    // Only the person's own gesture decides. A finger reports
                    // tracking or interacting first; the app's own scrolls go
                    // straight to animating, and content growth reports nothing.
                    switch phase {
                    case .tracking, .interacting:
                        self.isPersonScrolling = true
                    case .idle:
                        if self.isPersonScrolling {
                            self.isPersonScrolling = false
                            self.isFollowing = self.isNearEnd
                        }
                    default:
                        break
                    }
                }
                .onChange(of: self.model.messages.count) {
                    if self.model.messages.last?.role == .user { self.isFollowing = true }
                    self.follow(proxy, animated: true)
                }
                .onChange(of: self.model.streamingReply) { self.follow(proxy, animated: false) }
                .onChange(of: self.model.liveActivity) { self.follow(proxy, animated: true) }
                .onChange(of: self.model.approvals.map(\.id)) { self.follow(proxy, animated: true) }
                .onChange(of: self.model.questions.map(\.id)) { self.follow(proxy, animated: true) }
                .onChange(of: self.model.lastError) { self.follow(proxy, animated: true) }
            }

            Divider()
            if let request = self.permissions.pendingRequest {
                PermissionRequestBanner(
                    request: request,
                    onAllow: {
                        // A write that carries a warning is not granted from a
                        // banner; the Permissions page presents the warning.
                        if !self.permissions.allowPendingRequest() { self.isPermissionsPresented = true }
                    },
                    onDismiss: { self.permissions.dismissPendingRequest() })
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            if !self.model.messages.isEmpty, self.setup.state == .needsSignIn {
                SetupBanner(setup: self.setup)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            Composer(model: self.model, dictation: self.model.dictation)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .overlay {
            if let approval = self.model.approvals.first {
                ApprovalSheet(approval: approval, model: self.model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: self.model.approvals.first?.id)
        .font(OperatorLettering.font(.body))
        .narrowedLettering()
        .background(OperatorBrand.nearBlack)
        .foregroundStyle(OperatorBrand.light)
        .tint(OperatorBrand.vermilion)
        .preferredColorScheme(.dark)
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
                    .operatorSheetStyle()
        }
        // First launch: the Permissions page before anything else, with
        // nothing selected. A cover rather than a sheet so it can coexist with
        // the model-setup sheet on the same view and cannot be swiped away.
        .fullScreenCover(isPresented: Binding(
            get: { !self.permissions.hasCompletedOnboarding },
            set: { if !$0 { self.permissions.completeOnboarding() } }))
        {
            ConnectorPermissionsScreen(
                center: self.permissions, mode: .onboarding,
                accountStatus: self.accountStatus,
                onDone: { self.permissions.completeOnboarding() })
                    .operatorSheetStyle()
        }
    }
}

private struct Header: View {
    let state: ConnectionState
    let mark: OperatorMarkState

    var body: some View {
        HStack {
            OperatorMark(state: self.mark)
                .keepsShape()
            Text("Operator")
                .font(OperatorLettering.font(.headline, .bold))
            Spacer()
            Label(self.state.title, systemImage: self.state.symbol)
                .labelStyle(.titleAndIcon)
                .font(OperatorLettering.font(.caption, .medium))
                .foregroundStyle(self.state == .offline ? OperatorBrand.dim : OperatorBrand.muted)
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
                .font(OperatorLettering.font(.title2, .bold))
            Text("One conversation. Ask for anything.")
                .font(OperatorLettering.font(.subheadline))
                .foregroundStyle(OperatorBrand.muted)
            if self.setup.state == .needsSignIn {
                Button("Connect ChatGPT") {
                    Task { await self.setup.beginChatGPTSignIn() }
                }
                .buttonStyle(OperatorPrimaryButtonStyle())
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
                    .foregroundStyle(OperatorBrand.muted)
                Button("Retry account check") {
                    Task { await self.setup.retryAccountCheck() }
                }
                .buttonStyle(OperatorQuietButtonStyle())
            case let .failed(message):
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Retry account check") {
                    Task { await self.setup.retryAccountCheck() }
                }
                .buttonStyle(OperatorQuietButtonStyle())
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
                .font(OperatorLettering.font(.footnote))
            Spacer()
            Button("Connect") {
                Task { await self.setup.beginChatGPTSignIn() }
            }
            .font(OperatorLettering.font(.footnote, .medium))
        }
        .padding(10)
        .background(
            OperatorBrand.fill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    /// What the agent did to produce this reply, this launch. Empty for
    /// anything restored from disk.
    var steps: [ChatActivityStep] = []
    /// The runtime has taken this message; the activity bubble shows the rest.
    var inFlight = false

    var body: some View {
        VStack(alignment: self.message.role == .user ? .trailing : .leading, spacing: 4) {
            ForEach(self.steps) { step in
                ActivityStepRow(step: step)
            }
            if case let .weather(card) = self.message.attachment {
                WeatherResultCard(card: card)
            } else {
                if self.message.role == .user {
                    Text(ChatMessageText.displayText(for: self.message))
                        .textSelection(.enabled)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(OperatorBrand.fillStrong, in: PersonBubbleShape())
                        .padding(.leading, 48)
                } else {
                    Text(ChatMessageText.displayText(for: self.message))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .padding(.horizontal, 2)
                }
            }
            if let state = ChatMessageText.deliveryLabel(for: self.message, inFlight: self.inFlight) {
                Text(state)
                    .font(OperatorLettering.font(.caption2))
                    .foregroundStyle(OperatorBrand.muted)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: self.message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ChatMessageText.accessibilityLabel(for: self.message, inFlight: self.inFlight))
    }
}

private struct WeatherResultCard: View {
    let card: WeatherCard
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weather").font(OperatorLettering.font(.headline, .bold))
            Text(self.card.condition).font(OperatorLettering.font(.subheadline))
            Text("\(self.card.temperatureCelsius, format: .number.precision(.fractionLength(0)))°C").font(OperatorLettering.font(.title2, .bold))
            if let apparent = self.card.apparentCelsius { Text("Feels like \(apparent, format: .number.precision(.fractionLength(0)))°C").font(OperatorLettering.font(.footnote)).foregroundStyle(OperatorBrand.muted) }
            if let high = self.card.highCelsius, let low = self.card.lowCelsius { Text("High \(high, format: .number.precision(.fractionLength(0)))° · Low \(low, format: .number.precision(.fractionLength(0)))°").font(OperatorLettering.font(.footnote)).foregroundStyle(OperatorBrand.muted) }
            HStack { AsyncImage(url: self.colorScheme == .dark ? self.card.attribution.combinedMarkDarkURL : self.card.attribution.combinedMarkLightURL) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(height: 20).accessibilityLabel("Apple Weather"); Spacer(); Link("Legal", destination: self.card.attribution.legalPageURL).font(OperatorLettering.font(.footnote)) }
        }
        .padding(14)
        .background(OperatorBrand.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The reply in progress, from the moment of sending: three dots while the
/// model thinks, each tool call as it runs (the exact tool and arguments,
/// the way a terminal agent shows them), then the text as it streams.
private struct ActivityBubble: View {
    let activity: ChatLiveActivity
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(self.activity.steps) { step in
                ActivityStepRow(step: step)
            }
            if self.text == nil, !self.activity.commentary.isEmpty || !self.activity.reasoning.isEmpty {
                ThinkingBox(commentary: self.activity.commentary, reasoning: self.activity.reasoning)
            }
            if let text {
                HStack(alignment: .bottom, spacing: 8) {
                    Text(ChatMessageText.assistantText(text))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .padding(.horizontal, 2)
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Operator is writing")
                }
            } else {
                TypingDots()
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                    .accessibilityLabel(self.activity.steps.contains { $0.state == .running } ? "Operator is running a tool" : "Operator is thinking")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Checking Discord announcements" with the state in the marker: a spinner
/// while it runs, a check when it is done, a warning when it failed. The
/// exact call is in the accessibility label, not on screen.
private struct ActivityStepRow: View {
    let step: ChatActivityStep

    /// Reads stay a quiet line; something Operator did gets a card.
    private var isWrite: Bool { OperatorSound.forFinishedStep(named: self.step.name) != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                switch self.step.state {
                case .running:
                    ProgressView().controlSize(.mini)
                case .done where self.isWrite:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(OperatorBrand.vermilion).keepsShape()
                case .done:
                    Circle().fill(OperatorBrand.dim).frame(width: 6, height: 6).keepsShape()
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(OperatorBrand.rust)
                }
            }
            .frame(width: 14, height: 14)
            Text(self.step.title)
                .font(OperatorLettering.font(self.isWrite ? .subheadline : .footnote, self.isWrite ? .medium : .regular))
                .foregroundStyle(self.isWrite || self.step.state == .running ? OperatorBrand.light : OperatorBrand.muted)
                .lineLimit(2)
        }
        .padding(.horizontal, self.isWrite ? 14 : 2)
        .padding(.vertical, self.isWrite ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(self.isWrite ? OperatorBrand.fill : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.step.state == .failed ? "\(self.step.title), failed. \(self.step.call)" : "\(self.step.title). \(self.step.call)")
    }
}

/// What the model is thinking while it drafts: its commentary lines and the
/// tail of its reasoning, quiet and italic. Present only until the reply
/// text starts; the steps above it are what remain afterwards.
private struct ThinkingBox: View {
    let commentary: [String]
    let reasoning: String

    private var reasoningTail: String {
        let lines = self.reasoning.split(separator: "\n", omittingEmptySubsequences: true).suffix(4)
        let tail = lines.joined(separator: "\n")
        return tail.count > 400 ? "…" + tail.suffix(400) : tail
    }

    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { self.isOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(OperatorBrand.rust)
                        .rotationEffect(.degrees(self.isOpen ? 90 : 0))
                    Text("Thinking")
                        .font(OperatorLettering.font(.footnote))
                        .foregroundStyle(OperatorBrand.muted)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -14)
            .accessibilityHint(self.isOpen ? "Hides what Operator is thinking" : "Shows what Operator is thinking")
            if self.isOpen { self.thoughts.padding(.leading, 17) }
        }
        .padding(.horizontal, 2)
    }

    private var thoughts: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(self.commentary.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(OperatorLettering.font(.footnote))
                    .foregroundStyle(OperatorBrand.muted)
            }
            if !self.reasoning.isEmpty {
                Text(self.reasoningTail)
                    .font(OperatorLettering.font(.footnote))
                    .italic()
                    .foregroundStyle(OperatorBrand.dim)
                    .lineLimit(6)
                    .transaction { $0.animation = nil }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Operator is thinking: \(self.commentary.joined(separator: ". "))")
    }
}

/// Three dots that pulse in turn.
private struct TypingDots: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(OperatorBrand.muted)
                    .frame(width: 8, height: 8)
                    .keepsShape()
                    .opacity(self.isAnimating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(index) * 0.18),
                        value: self.isAnimating)
            }
        }
        .onAppear { self.isAnimating = true }
        .accessibilityHidden(true)
    }
}

/// One corner tight, the way a speech bubble points at its speaker.
private struct PersonBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: 16, bottomLeading: 16, bottomTrailing: 5, topTrailing: 16), style: .continuous)
    }
}

/// Operator has stopped for a yes or no: everything else dims and the
/// question rises from the bottom with one clear action.
private struct ApprovalSheet: View {
    let approval: GatewayApprovalSnapshot
    @ObservedObject var model: ChatSessionModel

    private var allows: [GatewayApprovalDecision] { self.approval.presentation.allowedDecisions.filter { $0 != .deny } }

    var body: some View {
        VStack(spacing: 0) {
            OperatorBrand.nearBlack.opacity(0.74).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("OPERATOR NEEDS YOUR OK")
                    .font(OperatorLettering.font(.caption2))
                    .kerning(1.3)
                    .foregroundStyle(OperatorBrand.vermilion)
                Text(self.approval.presentation.title)
                    .font(OperatorLettering.font(.title3, .bold))
                Text(self.approval.presentation.detail)
                    .font(OperatorLettering.font(.footnote))
                    .foregroundStyle(OperatorBrand.muted)
                    .textSelection(.enabled)
                if let warning = self.approval.presentation.warning {
                    Text(warning)
                        .font(OperatorLettering.font(.footnote))
                        .foregroundStyle(OperatorBrand.vermilion)
                }
                VStack(spacing: 8) {
                    ForEach(Array(self.allows.enumerated()), id: \.offset) { index, decision in
                        Button { self.model.resolveApproval(id: self.approval.id, decision: decision) } label: {
                            Text(self.label(for: decision))
                                .font(OperatorLettering.font(.subheadline, .medium))
                                .foregroundStyle(index == 0 ? OperatorBrand.nearBlack : OperatorBrand.light)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(index == 0 ? OperatorBrand.vermilion : OperatorBrand.fillStrong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if self.approval.presentation.allowedDecisions.contains(.deny) {
                        Button { self.model.resolveApproval(id: self.approval.id, decision: .deny) } label: {
                            Text(self.label(for: .deny))
                                .font(OperatorLettering.font(.footnote))
                                .foregroundStyle(OperatorBrand.light.opacity(0.8))
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .disabled(!self.approval.isActionable())
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack { OperatorBrand.nearBlack; OperatorBrand.light.opacity(0.07) }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous))
                    .ignoresSafeArea(edges: .bottom))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Action needs your approval: \(self.approval.presentation.title)")
        .accessibilityAddTraits(.isModal)
    }

    private func label(for decision: GatewayApprovalDecision) -> String {
        switch decision {
        case .allowOnce: "Allow once"
        case .allowAlways: "Always allow"
        case .deny: "Deny"
        }
    }
}

/// The model's question, waiting on the person: the run cannot continue
/// until it is answered or skipped. One tap answers a single-choice
/// question; anything else collects and sends once. Carries the "Needs your
/// answer" mark, and never the send-style prominence of an approval, since
/// nothing leaves the phone on an answer.
private struct QuestionCard: View {
    let record: GatewayQuestionRecord
    @ObservedObject var model: ChatSessionModel
    @State private var chosen: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    private var needsSendButton: Bool {
        self.record.questions.count > 1 || self.record.questions.contains { $0.multiSelect || $0.acceptsFreeText }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEEDS YOUR ANSWER")
                .font(OperatorLettering.font(.caption2))
                .kerning(1.3)
                .foregroundStyle(OperatorBrand.vermilion)
            ForEach(self.record.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if !question.header.isEmpty {
                        Text(question.header.uppercased())
                            .font(OperatorLettering.font(.caption2, .medium))
                            .foregroundStyle(OperatorBrand.muted)
                    }
                    Text(question.question)
                        .font(OperatorLettering.font(.subheadline, .medium))
                        .textSelection(.enabled)
                    ForEach(question.options, id: \.label) { option in
                        self.optionButton(option, for: question)
                    }
                    if question.acceptsFreeText {
                        TextField(
                            question.options.isEmpty ? "Your answer" : "Or type your own",
                            text: Binding(
                                get: { self.typed[question.questionId] ?? "" },
                                set: { self.typed[question.questionId] = $0 }),
                            axis: .vertical)
                            .lineLimit(1 ... 4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(OperatorBrand.fillStrong, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel("Answer: \(question.question)")
                    }
                }
            }
            HStack(spacing: 8) {
                if self.needsSendButton {
                    Button("Send answer") { self.send() }
                        .buttonStyle(OperatorPrimaryButtonStyle())
                        .disabled(!self.record.isActionable() || self.answers() == nil)
                }
                Button("Skip") { self.model.skipQuestion(id: self.record.id) }
                    .buttonStyle(OperatorQuietButtonStyle())
                    .disabled(!self.record.isActionable())
            }
        }
        .padding(14)
        .background(OperatorBrand.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs your answer: \(self.record.questions.map(\.question).joined(separator: " "))")
    }

    @ViewBuilder
    private func optionButton(_ option: GatewayQuestionOption, for question: GatewayQuestion) -> some View {
        let isChosen = self.chosen[question.questionId]?.contains(option.label) ?? false
        Button {
            if self.needsSendButton {
                self.toggle(option.label, for: question)
            } else {
                self.model.answerQuestion(id: self.record.id, answers: [question.questionId: [option.label]])
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if question.multiSelect {
                    Image(systemName: isChosen ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isChosen ? Color.accentColor : OperatorBrand.muted)
                } else if self.needsSendButton {
                    Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isChosen ? Color.accentColor : OperatorBrand.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(OperatorLettering.font(.subheadline))
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(OperatorLettering.font(.footnote))
                            .foregroundStyle(OperatorBrand.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(isChosen ? OperatorBrand.vermilion : OperatorBrand.light)
        .disabled(!self.record.isActionable())
        .accessibilityLabel(option.label)
        .accessibilityHint(option.description ?? "")
    }

    private func toggle(_ label: String, for question: GatewayQuestion) {
        var set = self.chosen[question.questionId] ?? []
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        self.chosen[question.questionId] = set
    }

    /// Every question answered, or nil while one is still blank.
    private func answers() -> [String: [String]]? {
        var answers: [String: [String]] = [:]
        for question in self.record.questions {
            let picked = Array(self.chosen[question.questionId] ?? []).sorted()
            let text = (self.typed[question.questionId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !picked.isEmpty { answers[question.questionId] = picked }
            else if question.acceptsFreeText, !text.isEmpty { answers[question.questionId] = [text] }
            else { return nil }
        }
        return answers
    }

    private func send() {
        guard let answers = self.answers() else { return }
        self.model.answerQuestion(id: self.record.id, answers: answers)
    }
}

/// Where a question was, once it is answered: what the person chose.
private struct AnsweredQuestionLine: View {
    let answered: AnsweredQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(self.answered.prompts.enumerated()), id: \.offset) { _, prompt in
                Text(prompt)
                    .font(OperatorLettering.font(.footnote))
                    .foregroundStyle(OperatorBrand.muted)
            }
            Text("You answered: \(self.answered.chosen.joined(separator: ", "))")
                .font(OperatorLettering.font(.footnote, .medium))
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct Composer: View {
    @ObservedObject var model: ChatSessionModel
    @ObservedObject var dictation: OfflineDictationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Ask for something you want done",
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
                        OperatorBrand.fill,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("Message Operator")
                    .accessibilityIdentifier("chat-composer")

                Button(action: self.toggleDictation) {
                    Image(systemName: self.dictation.state == .recording ? "stop.fill" : "mic.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(self.dictation.state == .recording ? OperatorBrand.nearBlack : OperatorBrand.light)
                .background(
                    self.dictation.state == .recording ? OperatorBrand.vermilion : OperatorBrand.fillStrong,
                    in: Circle())
                .accessibilityLabel(self.dictation.state == .recording ? "Stop dictation" : "Start offline dictation")
                .accessibilityHint("Adds on-device speech to the editable message draft")

                // Stop while it works, unless something is typed: then Send,
                // which adds the message to the work already running.
                if self.model.connectionState == .working,
                   self.model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    Button(action: self.model.stop) {
                        Image(systemName: "stop.fill")
                            .frame(width: 28, height: 28)
                            .foregroundStyle(OperatorBrand.nearBlack)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(OperatorBrand.vermilion, in: Circle())
                    .accessibilityLabel("Stop Operator")
                } else {
                    Button(action: self.model.send) {
                        Image(systemName: "arrow.up")
                            .font(OperatorLettering.font(.headline, .bold))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(self.model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OperatorBrand.dim : OperatorBrand.nearBlack)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(self.model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OperatorBrand.fillStrong : OperatorBrand.vermilion, in: Circle())
                    .disabled(self.model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            if case let .unavailable(message) = self.dictation.state {
                Text(message)
                    .font(OperatorLettering.font(.footnote))
                    .foregroundStyle(OperatorBrand.muted)
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
