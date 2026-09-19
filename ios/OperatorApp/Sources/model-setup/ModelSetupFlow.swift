import Combine
import OSLog
import SwiftUI
import UIKit

@MainActor
final class ModelSetupModel: ObservableObject {
    @Published private(set) var state: ModelSetupState = .checking
    @Published private(set) var isPresented = false

    private let gateway: any ModelSetupGateway
    private let activationCompleted: @MainActor @Sendable () async throws -> Void
    private var sessionID: String?
    private var pendingActivation: ModelSetupActivation?
    private var pendingClientStep: ModelSetupWizardStep?
    private var setupGeneration = 0
    private let logger = Logger(subsystem: "app.operator.ios", category: "model-setup-flow")

    init(
        gateway: any ModelSetupGateway,
        activationCompleted: @escaping @MainActor @Sendable () async throws -> Void = {})
    {
        self.gateway = gateway
        self.activationCompleted = activationCompleted
    }

    func check() async {
        guard !self.hasActiveSetup else {
            self.logger.info("[setup] foreground check preserved active authorization")
            return
        }
        self.setupGeneration &+= 1
        let checkGeneration = self.setupGeneration
        self.logger.info("[setup] checking configuration generation=\(checkGeneration)")
        self.state = .checking
        do {
            let configuration = try await self.gateway.configuration()
            guard !self.hasActiveSetup, checkGeneration == self.setupGeneration else {
                self.logger.info("[setup] ignored older configuration result generation=\(checkGeneration)")
                return
            }
            self.state = configuration.hasConfiguredModel ? .ready : .needsSignIn
            self.logger.info("[setup] configuration applied generation=\(checkGeneration) configured=\(configuration.hasConfiguredModel)")
        } catch {
            guard !self.hasActiveSetup, checkGeneration == self.setupGeneration else {
                self.logger.info("[setup] ignored older configuration failure generation=\(checkGeneration)")
                return
            }
            self.state = .unavailable
            self.logger.error("[setup] configuration unavailable generation=\(checkGeneration)")
        }
    }

    func retryAccountCheck() async {
        await self.check()
    }

    func beginChatGPTSignIn() async {
        guard !self.hasActiveSetup else {
            self.logger.info("[setup] preserved active authorization instead of starting another")
            return
        }
        self.setupGeneration &+= 1
        self.pendingActivation = nil
        self.pendingClientStep = nil
        self.isPresented = true
        self.state = .starting
        let sessionID = UUID().uuidString.lowercased()
        self.sessionID = sessionID
        do {
            let result = try await self.gateway.startDeviceCode(sessionID: sessionID)
            try await self.advanceUntilUserAction(from: result)
        } catch {
            self.sessionID = nil
            self.state = .failed("ChatGPT sign-in could not start. Try again.")
        }
    }

    private var hasActiveSetup: Bool {
        self.sessionID != nil || self.pendingActivation != nil || self.pendingClientStep != nil
    }

    func continueSignIn() async {
        guard case let .awaitingAuthorization(step) = self.state,
              let sessionID
        else { return }
        self.state = .starting
        do {
            let result = try await self.gateway.next(
                sessionID: sessionID,
                answeringStepID: step.id)
            try await self.advanceUntilUserAction(from: result)
        } catch {
            self.state = .failed("ChatGPT sign-in did not finish. Try again.")
        }
    }

    func retry() async {
        if let activation = self.pendingActivation {
            self.logger.info("[setup] retrying saved activation verification")
            do {
                try await self.finishActivation(activation)
            } catch {
                self.state = .failed("Saved sign-in could not be verified. Try again.")
            }
        } else if self.sessionID == nil {
            self.logger.info("[setup] retrying authorization start with a fresh session")
            await self.beginChatGPTSignIn()
        } else if let step = self.pendingClientStep {
            self.logger.info("[setup] retrying authorization response in its existing session")
            self.state = .awaitingAuthorization(step)
            await self.continueSignIn()
        } else {
            self.logger.info("[setup] restarting authorization because no client step was saved")
            await self.beginChatGPTSignIn()
        }
    }

    func dismiss() {
        guard self.isPresented else { return }
        self.setupGeneration &+= 1
        self.pendingActivation = nil
        self.pendingClientStep = nil
        let sessionID = self.sessionID
        self.sessionID = nil
        self.isPresented = false
        self.state = .needsSignIn
        if let sessionID {
            Task { await self.gateway.cancel(sessionID: sessionID) }
        }
    }

    private func advanceUntilUserAction(from initial: ModelSetupWizardResult) async throws {
        var result = initial
        if let returnedSessionID = result.sessionID {
            self.sessionID = returnedSessionID
        }
        for _ in 0 ..< 32 {
            if result.done {
                try await self.finish(result)
                return
            }
            if let step = result.step, step.executor != "gateway" {
                self.pendingClientStep = step
                self.state = .awaitingAuthorization(step)
                return
            }
            guard let sessionID else {
                throw ModelSetupFlowError.missingSession
            }
            result = try await self.gateway.next(
                sessionID: sessionID,
                answeringStepID: nil)
        }
        throw ModelSetupFlowError.tooManyGatewaySteps
    }

    private func finish(_ result: ModelSetupWizardResult) async throws {
        guard result.status == "done", let activation = result.modelActivation else {
            throw ModelSetupFlowError.authorizationFailed(result.error)
        }
        self.pendingActivation = activation
        try await self.finishActivation(activation)
    }

    private func finishActivation(_ activation: ModelSetupActivation) async throws {
        let restartRequired = activation.gatewayRestartRequired == true
        self.state = restartRequired ? .restarting : .starting
        try await self.gateway.verifyActivation(activation)
        await self.gateway.disconnect()
        try await self.activationCompleted()
        self.pendingActivation = nil
        self.pendingClientStep = nil
        self.sessionID = nil
        self.state = .ready
        self.isPresented = false
    }
}

private enum ModelSetupFlowError: Error {
    case missingSession
    case tooManyGatewaySteps
    case authorizationFailed(String?)
}

struct ModelSetupSheet: View {
    @ObservedObject var model: ModelSetupModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                self.content
                    .frame(maxWidth: 440)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Connect ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: self.model.dismiss)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch self.model.state {
        case .starting, .checking:
            ProgressView("Preparing secure sign-in…")
        case .restarting:
            ProgressView("Finishing setup…")
        case let .awaitingAuthorization(step):
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(step.title ?? "Authorize ChatGPT")
                    .font(OperatorLettering.font(.title2, .bold))
                if let message = step.deviceCode?.message ?? step.message {
                    Text(message)
                        .font(OperatorLettering.font(.subheadline))
                        .foregroundStyle(OperatorBrand.muted)
                        .multilineTextAlignment(.center)
                }
                if let code = step.deviceCode?.code {
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label(code, systemImage: "doc.on.doc")
                            .font(.title3.monospaced().weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Copies the one-time code")
                }
                if let minutes = step.deviceCode?.expiresInMinutes {
                    Text("Expires in \(minutes) minutes")
                        .font(OperatorLettering.font(.caption))
                        .foregroundStyle(OperatorBrand.muted)
                }
                if let url = step.externalURL {
                    Link("Open sign-in page", destination: url)
                        .buttonStyle(OperatorPrimaryButtonStyle())
                }
                Button("Continue") {
                    Task { await self.model.continueSignIn() }
                }
                .buttonStyle(OperatorPrimaryButtonStyle())
            }
        case let .failed(message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(OperatorLettering.font(.largeTitle, .bold))
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await self.model.retry() }
                }
                .buttonStyle(OperatorPrimaryButtonStyle())
            }
        case .ready:
            Label("ChatGPT is connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(OperatorBrand.vermilion)
        case .needsSignIn, .unavailable:
            Button("Start secure sign-in") {
                Task { await self.model.beginChatGPTSignIn() }
            }
            .buttonStyle(OperatorPrimaryButtonStyle())
        }
    }
}
