// Operator's UTM SE app root. Applied over Platform/iOS/UTMApp.swift in UTM 4.7.5.

import Foundation
import SwiftUI
import UIKit

struct OperatorLaunchCredentials: Sendable {
    let gatewayToken: String
    let deviceID: String
    let devicePublicKey: String
}

@MainActor
final class OperatorVMAdapter: ObservableObject {
    enum State: Equatable {
        case guestNotBundled
        case ready
        case starting
        case running
        case saving
        case suspended
        case failed(String)
    }

    @Published private(set) var state: State = .guestNotBundled

    private let guestResourceName = "Operator"
    private var virtualMachine: UTMQemuVirtualMachine?
    private var hasUncertainGuestState = false

    var statusText: String {
        switch state {
        case .guestNotBundled: return "Guest not bundled"
        case .ready: return "Ready"
        case .starting: return "Starting"
        case .running: return "Running"
        case .saving: return "Saving state"
        case .suspended: return "Saved"
        case .failed(let message): return message
        }
    }

    @discardableResult
    func prepareBundledGuest() -> Bool {
        if self.virtualMachine != nil {
            return true
        }
        do {
            let packageURL = try installBundledGuestIfNeeded()
            guard let configuration = try UTMQemuConfiguration.load(from: packageURL) as? UTMQemuConfiguration else {
                throw UTMConfigurationError.invalidBackend
            }
            virtualMachine = try UTMQemuVirtualMachine(packageUrl: packageURL, configuration: configuration)
            state = .ready
            logger.info("[operator-utm] prepared bundled guest at \(packageURL.lastPathComponent)")
            return true
        } catch OperatorVMAdapterError.guestNotBundled {
            state = .guestNotBundled
            logger.info("[operator-utm] no Operator.utm resource is bundled")
            return false
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("[operator-utm] failed to prepare guest: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func start(credentials: OperatorLaunchCredentials) async -> Bool {
        guard !hasUncertainGuestState else {
            state = .failed(OperatorVMAdapterError.guestNeedsRelaunch.localizedDescription)
            logger.error("[operator-utm] refusing to replace guest after an uncertain pause or resume")
            return false
        }
        guard let virtualMachine else {
            state = .failed(OperatorVMAdapterError.guestNotPrepared.localizedDescription)
            return false
        }
        if virtualMachine.state == .started {
            state = .running
            return true
        }
        if virtualMachine.state == .paused {
            do {
                try await virtualMachine.resume()
                UTMRegistry.shared.sync()
                state = .running
                logger.info("[operator-utm] resumed paused guest and persisted registry")
                return true
            } catch {
                hasUncertainGuestState = true
                state = .failed(OperatorVMAdapterError.guestNeedsRelaunch.localizedDescription)
                logger.error("[operator-utm] guest resume failed: \(error.localizedDescription)")
                return false
            }
        }
        state = .starting
        let isRestoringSnapshot = virtualMachine.registryEntry.isSuspended
        logger.info("[operator-utm] starting guest restore=\(isRestoringSnapshot)")
        do {
            let launchFiles = try ProtectedLaunchFiles(credentials: credentials)
            let originalArguments = virtualMachine.config.qemu.additionalArguments
            virtualMachine.config.qemu.additionalArguments.append(contentsOf: Self.makeFwCfgArguments(fileURLs: launchFiles.urls))
            defer {
                virtualMachine.config.qemu.additionalArguments = originalArguments
                launchFiles.delete()
            }
            try await virtualMachine.start(options: [])
            UTMRegistry.shared.sync()
            state = .running
            logger.info("[operator-utm] guest started and persisted registry restore=\(isRestoringSnapshot)")
            return true
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("[operator-utm] guest start failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func makeFwCfgArguments(fileURLs: ProtectedLaunchFiles.URLs) -> [QEMUArgument] {
        [
            QEMUArgument("-fw_cfg"),
            QEMUArgument("name=opt/openclaw/gateway-token,file=\(fileURLs.gatewayToken.path)"),
            QEMUArgument("-fw_cfg"),
            QEMUArgument("name=opt/openclaw/device-id,file=\(fileURLs.deviceID.path)"),
            QEMUArgument("-fw_cfg"),
            QEMUArgument("name=opt/openclaw/device-public-key,file=\(fileURLs.devicePublicKey.path)"),
        ]
    }

    @discardableResult
    func saveSnapshot() async -> Bool {
        guard let virtualMachine else {
            state = .failed(OperatorVMAdapterError.guestNotPrepared.localizedDescription)
            return false
        }
        state = .saving
        logger.info("[operator-utm] saving guest state")
        do {
            if virtualMachine.state == .started {
                try await virtualMachine.pause()
            }
            try await virtualMachine.saveSnapshot(name: nil)
            UTMRegistry.shared.sync()
            state = .suspended
            logger.info("[operator-utm] paused guest state saved and registry persisted")
            return true
        } catch {
            hasUncertainGuestState = true
            state = .failed(OperatorVMAdapterError.guestNeedsRelaunch.localizedDescription)
            logger.error("[operator-utm] guest state save failed: \(error.localizedDescription)")
            return false
        }
    }

    func markSuspended() {
        self.state = .suspended
    }

    private func installBundledGuestIfNeeded() throws -> URL {
        guard let bundledURL = Bundle.main.url(forResource: guestResourceName, withExtension: "utm") else {
            throw OperatorVMAdapterError.guestNotBundled
        }
        let applicationSupportURL = try FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            .unwrap(or: OperatorVMAdapterError.applicationSupportUnavailable)
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        let packageURL = applicationSupportURL.appendingPathComponent("Operator.utm", isDirectory: true)
        if !FileManager.default.fileExists(atPath: packageURL.path) {
            try FileManager.default.copyItem(at: bundledURL, to: packageURL)
            logger.info("[operator-utm] copied bundled guest to Application Support")
        }
        try protectWritableGuest(at: packageURL)
        return packageURL
    }

    private func protectWritableGuest(at packageURL: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var writableURL = packageURL
        try writableURL.setResourceValues(values)

        let protectionAttributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        let contentPaths = try FileManager.default.subpathsOfDirectory(atPath: packageURL.path)
        for path in [packageURL.path] + contentPaths.map({ packageURL.appendingPathComponent($0).path }) {
            try FileManager.default.setAttributes(protectionAttributes, ofItemAtPath: path)
        }
        logger.info("[operator-utm] excluded writable guest from backup and applied after-first-unlock protection")
    }
}

private final class ProtectedLaunchFiles: @unchecked Sendable {
    struct URLs {
        let gatewayToken: URL
        let deviceID: URL
        let devicePublicKey: URL
    }

    let directoryURL: URL
    let urls: URLs

    init(credentials: OperatorLaunchCredentials) throws {
        let fileManager = FileManager.default
        directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("operator-launch-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        urls = URLs(
            gatewayToken: directoryURL.appendingPathComponent("gateway-token"),
            deviceID: directoryURL.appendingPathComponent("device-id"),
            devicePublicKey: directoryURL.appendingPathComponent("device-public-key"))
        do {
            try Self.write(credentials.gatewayToken, to: urls.gatewayToken)
            try Self.write(credentials.deviceID, to: urls.deviceID)
            try Self.write(credentials.devicePublicKey, to: urls.devicePublicKey)
            logger.info("[operator-utm] prepared three protected launch values")
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    func delete() {
        do {
            try FileManager.default.removeItem(at: directoryURL)
            logger.info("[operator-utm] deleted protected launch values")
        } catch {
            logger.error("[operator-utm] failed to delete protected launch values: \(error.localizedDescription)")
        }
    }

    private static func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private enum OperatorVMAdapterError: LocalizedError {
    case applicationSupportUnavailable
    case guestNotBundled
    case guestNotPrepared
    case guestNeedsRelaunch

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable: return "Application Support is unavailable."
        case .guestNotBundled: return "Operator.utm is not bundled."
        case .guestNotPrepared: return "Prepare the bundled guest before starting it."
        case .guestNeedsRelaunch: return "Close and reopen Operator to safely recover its local runtime."
        }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }
        return value
    }
}

@MainActor
private final class OperatorRuntimeCoordinator: ObservableObject {
    let chat: ChatSessionModel
    let whatsapp: WhatsAppLinkFlowModel
    let accounts: NativeAccountSetupCoordinator
    lazy var setup = ModelSetupModel(
        gateway: self.setupGateway,
        activationCompleted: { [weak self] in
            guard let self else { return }
            try await self.reconnectAfterModelSetup()
        })

    private let vault: GatewayInstallationVault
    private let setupGateway: LocalModelSetupGateway
    private let locationNode: LocalLocationNodeGateway
    private let vm = OperatorVMAdapter()
    private var lifecycle = RuntimeLifecycleMachine()
    private var pendingPhase: ScenePhase?
    private var isProcessingPhases = false

    init() {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        let persistence = CoreChatPersistence(
            fileURL: supportDirectory
                .appendingPathComponent("Operator", isDirectory: true)
                .appendingPathComponent("conversation.json"))
        let credentialStore = KeychainCredentialStore(service: "app.operator.ios.gateway")
        let vault = GatewayInstallationVault(store: credentialStore)
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let platform = "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let gatewayURL = URL(string: "ws://127.0.0.1:18789")!

        self.vault = vault
        self.whatsapp = WhatsAppLinkFlowModel(gateway: WhatsAppLinkGatewayClient(
            connectionFactory: {
                let credentials = try await vault.loadOrCreate()
                return OpenClawGatewayConnection(
                    transport: URLSessionGatewayTransport(url: gatewayURL, timeout: 30),
                    token: credentials.gatewayToken,
                    identity: credentials.identity,
                    metadata: GatewayConnectionMetadata(
                        appVersion: version, platform: platform, instanceID: credentials.instanceID))
            }))
        let accountSetup = NativeAccountSetupCoordinator(bundle: .main, presenter: SystemOAuthSessionPresenter())
        self.accounts = accountSetup
        self.chat = ChatSessionModel(
            store: persistence,
            gateway: LocalOpenClawChatGateway(
                url: gatewayURL,
                vault: vault,
                appVersion: version,
                platform: platform))
        self.setupGateway = LocalModelSetupGateway(
            url: gatewayURL,
            vault: vault,
            appVersion: version,
            platform: platform)
        let notionSetup = NativeNotionSetupCoordinator(bundle: .main, presenter: SystemOAuthSessionPresenter())
        let notionService = ForegroundNotionService(client: notionSetup.client, presenter: SystemNotionToolConfirmationPresenter(), isAppActive: { UIApplication.shared.applicationState == .active })
        self.locationNode = LocalLocationNodeGateway(
            url: gatewayURL,
            vault: vault,
            appVersion: version,
            platform: platform,
            handler: ForegroundNodeCommandRouter(
                location: ForegroundLocationService(),
                calendar: ForegroundCalendarService(),
                messages: ForegroundMessageComposeService(
                    presenter: SystemMessageComposer(),
                    isAppActive: { UIApplication.shared.applicationState == .active }),
                maps: ForegroundMapsService(),
                handoff: ForegroundAppHandoffService(),
                whatsapp: ForegroundWhatsAppReadService(client: NativeWhatsAppReadClient(supportDirectory: supportDirectory)),
                whatsappCompose: ForegroundWhatsAppComposeService(
                    presenter: SystemWhatsAppComposePresenter(),
                    sender: NativeWhatsAppSendClient(supportDirectory: supportDirectory),
                    isAppActive: { UIApplication.shared.applicationState == .active }),
                accounts: ForegroundAccountReadService(reader: DirectAccountReader(bearer: { provider in
                    try await accountSetup.accessToken(provider)
                })),
                accountWrite: ForegroundAccountWriteConfirmationService(
                    writer: DirectAccountWriter(bearer: { provider in try await accountSetup.accessToken(provider) }),
                    presenter: SystemAccountWriteConfirmationPresenter(),
                    isAppActive: { UIApplication.shared.applicationState == .active }),
                notion: notionService))
    }

    func handle(scenePhase: ScenePhase) {
        guard scenePhase == .active || scenePhase == .background else { return }
        if scenePhase == .background {
            self.chat.setForegroundActive(false)
        }
        self.pendingPhase = scenePhase
        guard !self.isProcessingPhases else { return }
        self.isProcessingPhases = true
        Task { [weak self] in
            await self?.processPendingPhases()
        }
    }

    private func processPendingPhases() async {
        defer { self.isProcessingPhases = false }
        while let phase = self.pendingPhase {
            self.pendingPhase = nil
            switch phase {
            case .active:
                await self.activateRuntime()
            case .background:
                await self.suspendRuntime()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func activateRuntime() async {
        let actions = self.lifecycle.handle(.becameActive)
        guard actions.contains(.start) || actions.contains(.restoreSnapshot) else {
            return
        }

        self.chat.runtimeIsStarting()
        self.chat.setForegroundActive(true)
        guard self.vm.prepareBundledGuest() else {
            self.failRuntime(self.vm.statusText)
            return
        }

        do {
            let launchCredentials = try await self.launchCredentials()
            guard await self.vm.start(credentials: launchCredentials) else {
                throw OperatorRuntimeCoordinatorError.vm(self.vm.statusText)
            }
            _ = self.lifecycle.handle(.started)
            self.chat.runtimeBecameReady()
            guard await self.chat.restoreAndWaitForGatewayReady() else {
                return
            }
            await self.locationNode.start()
            logger.info("[operator-runtime] guest started; chat readiness requires Gateway connection")
            Task { [weak self] in
                guard let self else { return }
                await self.setup.check()
            }
        } catch {
            self.failRuntime(error.localizedDescription)
        }
    }

    private func suspendRuntime() async {
        let actions = self.lifecycle.handle(.enteredBackground)
        guard actions.contains(.saveSnapshot) else { return }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Save Operator runtime") {
                logger.error("[operator-runtime] background snapshot time expired")
            }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        await self.locationNode.stop()
        self.chat.runtimeDidSuspend()
        guard await self.vm.saveSnapshot() else {
            self.failRuntime(self.vm.statusText)
            return
        }
        self.vm.markSuspended()
        _ = self.lifecycle.handle(.snapshotSaved)
        logger.info("[operator-runtime] phone-local runtime snapshot saved")
    }

    private func reconnectAfterModelSetup() async throws {
        self.chat.runtimeIsStarting()
        await self.locationNode.stop()
        self.chat.runtimeBecameReady()
        guard await self.chat.restoreAndWaitForGatewayReady() else {
            logger.error("[operator-runtime] chat reconnect failed after verified model setup")
            throw OperatorRuntimeCoordinatorError.gatewayNotReady
        }
        await self.locationNode.start()
        logger.info("[operator-runtime] reconnected after verified model setup")
    }

    private func launchCredentials() async throws -> OperatorLaunchCredentials {
        let credentials = try await self.vault.loadOrCreate()
        return OperatorLaunchCredentials(
            gatewayToken: credentials.gatewayToken,
            deviceID: credentials.identity.deviceID,
            devicePublicKey: Self.base64URL(credentials.identity.publicKey))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func failRuntime(_ message: String) {
        _ = self.lifecycle.handle(.failed(message))
        self.chat.runtimeFailed(message)
        logger.error("[operator-runtime] runtime unavailable: \(message)")
    }
}

private enum OperatorRuntimeCoordinatorError: LocalizedError {
    case vm(String)
    case gatewayNotReady

    var errorDescription: String? {
        switch self {
        case .vm(let message): return message
        case .gatewayNotReady: return "Model setup finished, but Operator could not reconnect. Try again."
        }
    }
}

private struct OperatorRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var runtime = OperatorRuntimeCoordinator()

    var body: some View {
        ZStack {
            ChatScreen(model: self.runtime.chat, setup: self.runtime.setup, whatsapp: self.runtime.whatsapp, accounts: self.runtime.accounts)
            if self.scenePhase != .active {
                OperatorPrivacyCover()
            }
        }
            .task {
                self.runtime.handle(scenePhase: self.scenePhase)
            }
            .onChange(of: self.scenePhase) { _, phase in
                self.runtime.handle(scenePhase: phase)
            }
    }
}

private struct OperatorPrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title)
                Text("Operator is hidden")
                    .font(.headline)
            }
            .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Operator content hidden while app is inactive")
    }
}

struct UTMApp: App {
    var body: some Scene {
        WindowGroup {
            OperatorRootView()
        }
    }
}
