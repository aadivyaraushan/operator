import Foundation
import OperatorCore
import SwiftUI
import UIKit

@MainActor
final class ForegroundRuntimeCoordinator {
    private let waitForChatGateway: () async -> Bool
    private let startNode: () async -> Void
    private let stopNode: () async -> Void
    private var startupTask: Task<Void, Never>?

    init(
        waitForChatGateway: @escaping () async -> Bool,
        startNode: @escaping () async -> Void,
        stopNode: @escaping () async -> Void)
    {
        self.waitForChatGateway = waitForChatGateway
        self.startNode = startNode
        self.stopNode = stopNode
    }

    func setForegroundActive(_ isActive: Bool) {
        guard isActive else {
            self.startupTask?.cancel()
            self.startupTask = nil
            Task { await self.stopNode() }
            return
        }
        guard self.startupTask == nil else { return }
        self.startupTask = Task { @MainActor [weak self] in
            guard let self,
                  await self.waitForChatGateway(),
                  !Task.isCancelled
            else { return }
            await self.startNode()
            self.startupTask = nil
        }
    }
}

@main
@MainActor
struct OperatorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var runtimeIsForeground = false
    @StateObject private var chat: ChatSessionModel
    @StateObject private var setup: ModelSetupModel
    @StateObject private var whatsapp: WhatsAppLinkFlowModel
    @StateObject private var accounts: NativeAccountSetupCoordinator
    @StateObject private var notion: NativeNotionSetupCoordinator
    @StateObject private var youtube: YouTubeAPIKeySetupModel
    @StateObject private var discord: DiscordAccountSetupModel
    @StateObject private var permissions: ConnectorPermissionCenter
    private let locationNode: LocalLocationNodeGateway
    private let foregroundRuntime: ForegroundRuntimeCoordinator
    private let embeddedRuntime: EmbeddedRuntimeHost
    private let runtimeToken: () async throws -> String

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
        // Zero fails runtime readiness if allocation fails; never fall back to
        // another app's server or compete for a hard-coded port.
        let gatewayPort = (try? LoopbackPort.allocate()) ?? 0
        self.embeddedRuntime = EmbeddedRuntimeHost(supportDirectory: supportDirectory, gatewayPort: gatewayPort)
        self.runtimeToken = { try await vault.loadOrCreate().gatewayToken }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let platform = "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let gatewayURL = URL(string: "ws://127.0.0.1:\(gatewayPort)")!
        let gateway = LocalOpenClawChatGateway(
            url: gatewayURL,
            vault: vault,
            appVersion: version,
            platform: platform)
        let chat = ChatSessionModel(
            store: persistence,
            gateway: gateway)
        let accountSetup = NativeAccountSetupCoordinator(
            bundle: .main,
            presenter: SystemOAuthSessionPresenter())
        let accountReader = ForegroundAccountReadService(
            reader: DirectAccountReader(bearer: { provider in
                try await accountSetup.accessToken(provider)
            }))
        let accountWrite = ForegroundAccountWriteConfirmationService(
            writer: DirectAccountWriter(bearer: { provider in
                try await accountSetup.accessToken(provider)
            }),
            presenter: SystemAccountWriteConfirmationPresenter(),
            isAppActive: { UIApplication.shared.applicationState == .active })
        let notionSetup = NativeNotionSetupCoordinator(
            bundle: .main,
            presenter: SystemOAuthSessionPresenter())
        let notionService = ForegroundNotionService(
            client: notionSetup.client,
            presenter: SystemNotionToolConfirmationPresenter(),
            isAppActive: { UIApplication.shared.applicationState == .active })
        let youtubeKeyStore = KeychainCredentialStore(
            service: "app.operator.ios.media",
            account: "youtube-api-key")
        let youtubeSetup = YouTubeAPIKeySetupModel(storage: .init(
            load: { try await youtubeKeyStore.load() },
            save: { try await youtubeKeyStore.save($0) },
            clear: { try await youtubeKeyStore.remove() }))
        let mediaService = ForegroundMediaNodeService(
            apiKey: {
                guard let data = try await youtubeKeyStore.load(),
                      data.count <= 4_096,
                      let value = String(data: data, encoding: .utf8)
                else { return nil }
                return value
            },
            opener: InAppMediaOpener(),
            isAppActive: { UIApplication.shared.applicationState == .active })
        // Discord: the owner's own token in the Keychain, the channel list
        // beside the grants, and a pace guard the acknowledgement promises.
        let discordTokenStore = KeychainCredentialStore(
            service: "app.operator.ios.discord",
            account: "user-token")
        let discordChannels = UserDefaultsDiscordChannelStore()
        let discordSetup = DiscordAccountSetupModel(storage: .init(
            loadToken: {
                guard let data = try await discordTokenStore.load(), let value = String(data: data, encoding: .utf8) else { return nil }
                return value
            },
            saveToken: { try await discordTokenStore.save(Data($0.utf8)) },
            clearToken: { try await discordTokenStore.remove() },
            loadChannels: { discordChannels.load() },
            saveChannels: { discordChannels.save($0) }))
        let contactDirectory = SystemContactDirectory()
        let discordService = ForegroundDiscordAnnouncementsService(
            client: DiscordUserClient(token: {
                guard let data = try await discordTokenStore.load(), let value = String(data: data, encoding: .utf8) else { return nil }
                return value
            }),
            channels: { discordChannels.load() },
            pace: DiscordReadPace(history: UserDefaultsDiscordReadHistoryStore()),
            cache: FileDiscordReadCacheStore(supportDirectory: supportDirectory))
        let handoffCatalogData = Bundle.main.url(
            forResource: "android-handoff-catalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) } ?? Data("[]".utf8)
        let discovery = ForegroundConnectionDiscoveryService(
            catalogData: handoffCatalogData,
            setup: {
                let notionState: ConnectionDiscoverySetupState = switch notionSetup.state {
                case .idle: .idle; case .needsSetup: .needsSetup; case .authorizing: .authorizing
                case .connected: .connected; case .cancelled: .cancelled; case .failed: .failed
                }
                return OAuthProvider.allCases.map { provider in
                    let state: ConnectionDiscoverySetupState = switch accountSetup.state(for: provider) {
                    case .idle: .idle; case .needsSetup: .needsSetup; case .authorizing: .authorizing
                    case .connected: .connected; case .cancelled: .cancelled; case .failed: .failed
                    }
                    return ConnectionDiscoverySetupStatus(
                        provider: provider.rawValue,
                        state: state,
                        registrationAvailable: state != .needsSetup)
                } + [ConnectionDiscoverySetupStatus(
                    provider: "notion",
                    state: notionState,
                    registrationAvailable: notionSetup.state != .needsSetup),
                    ConnectionDiscoverySetupStatus(
                        provider: "whatsapp",
                        state: .notChecked,
                        registrationAvailable: true),
                    ConnectionDiscoverySetupStatus(
                        provider: "discord",
                        state: discordSetup.isConnected ? .connected : .needsSetup,
                        registrationAvailable: true)]
            })
        let setupGateway = LocalModelSetupGateway(
            url: gatewayURL,
            vault: vault,
            appVersion: version,
            platform: platform)
        // Every node command passes through the owner's grants before it
        // reaches a connector, and the model is offered only the tools those
        // grants allow. A fresh install grants nothing.
        let permissions = ConnectorPermissionCenter(store: UserDefaultsConnectorGrantStore())
        let whatsappRead = NativeWhatsAppReadClient(supportDirectory: supportDirectory)
        let messageSend = ForegroundMessageSendService(
            runner: SystemShortcutRunner(),
            isAppActive: { UIApplication.shared.applicationState == .active })
        let locationNode = LocalLocationNodeGateway(
            url: gatewayURL,
            vault: vault,
            appVersion: version,
            platform: platform,
            handler: PermissionGuardedNodeCommandHandler(center: permissions, next: ForegroundNodeCommandRouter(
                location: ForegroundLocationService(),
                calendar: ForegroundCalendarService(),
                reminders: ForegroundRemindersService(),
                contacts: ForegroundContactsService(directory: contactDirectory, isAppActive: { UIApplication.shared.applicationState == .active }),
                photos: ForegroundPhotosService(),
                music: ForegroundMusicService(),
                weather: ForegroundWeatherService(recordCard: { card in
                    try await chat.recordWeatherCard(card)
                }),
                device: ForegroundDeviceService(),
                messages: ForegroundMessageDispatchService(
                    compose: ForegroundMessageComposeService(
                        presenter: SystemMessageComposer(),
                        isAppActive: { UIApplication.shared.applicationState == .active }),
                    send: messageSend,
                    autosendAllowed: { permissions.grants.permits(.messagesAutosend, .write) },
                    recordAutosend: { command in
                        permissions.recordExternalOutcome(connector: .messagesAutosend, access: .write, command: command, succeeded: true)
                    }),
                messageSend: messageSend,
                maps: ForegroundMapsService(),
                handoff: ForegroundAppHandoffService(),
                whatsapp: ForegroundWhatsAppReadService(client: whatsappRead),
                whatsappCompose: ForegroundWhatsAppComposeService(
                    presenter: SystemWhatsAppComposePresenter(),
                    sender: NativeWhatsAppSendClient(supportDirectory: supportDirectory),
                    isAppActive: { UIApplication.shared.applicationState == .active },
                    guardrail: WhatsAppSendGuard(recipients: whatsappRead, history: UserDefaultsWhatsAppSendHistoryStore())),
                accounts: accountReader,
                accountWrite: accountWrite,
                discovery: discovery,
                media: mediaService,
                notion: notionService,
                discord: discordService,
                incomingMessages: ForegroundIncomingMessagesService(store: IncomingMessageStore(supportDirectory: supportDirectory)),
                contactCreate: ForegroundContactCreateService(
                    directory: contactDirectory,
                    presenter: SystemContactCreatePresenter(),
                    isAppActive: { UIApplication.shared.applicationState == .active }))),
            agentTools: { permissions.currentPublishedTools() })
        permissions.grantsDidChange = { Task { await locationNode.republishAgentTools() } }
        self.locationNode = locationNode
        self.foregroundRuntime = ForegroundRuntimeCoordinator(
            waitForChatGateway: { [weak chat] in
                guard let chat else { return false }
                return await chat.restoreAndWaitForGatewayReady()
            },
            startNode: { await locationNode.start() },
            stopNode: { await locationNode.stop() })
        _chat = StateObject(wrappedValue: chat)
        _setup = StateObject(wrappedValue: ModelSetupModel(gateway: setupGateway))
        _accounts = StateObject(wrappedValue: accountSetup)
        _notion = StateObject(wrappedValue: notionSetup)
        _youtube = StateObject(wrappedValue: youtubeSetup)
        _discord = StateObject(wrappedValue: discordSetup)
        _permissions = StateObject(wrappedValue: permissions)
        _whatsapp = StateObject(wrappedValue: WhatsAppLinkFlowModel(
            gateway: NativeWhatsAppLinkClient(supportDirectory: supportDirectory)))
    }

    var body: some Scene {
        WindowGroup {
            ChatScreen(model: self.chat, setup: self.setup, whatsapp: self.whatsapp, accounts: self.accounts, notion: self.notion, youtube: self.youtube, discord: self.discord, permissions: self.permissions)
                .onOpenURL { url in
                    // Shortcuts returning from sms.send. The only thing known
                    // is what Shortcuts reported; it goes in the session log.
                    if let outcome = ForegroundMessageSendService.callbackOutcome(url) {
                        self.permissions.recordExternalOutcome(
                            connector: .messagesAutosend, access: .write,
                            command: "\(GatewayNativeNodeSurface.messageSendCommand) shortcut \(outcome)",
                            succeeded: outcome == "success")
                    }
                }
                .onChange(of: self.scenePhase, initial: true) { _, phase in
                    // Permission alerts temporarily interrupt interaction; they do not leave the app.
                    if phase == .active {
                        self.runtimeIsForeground = true
                    } else if phase == .background {
                        self.runtimeIsForeground = false
                    }
                }
                .task(id: self.scenePhase) {
                    guard self.scenePhase == .active else { return }
                    // Restore account status independently so network refresh never delays chat startup.
                    async let accountStatus: Void = self.accounts.checkConnections()
                    async let notionStatus: Void = self.notion.checkConnection()
                    _ = await (accountStatus, notionStatus)
                }
                .task(id: self.runtimeIsForeground) {
                    if self.runtimeIsForeground {
                        self.chat.runtimeIsStarting()
                        self.chat.setForegroundActive(true)
                        do {
                            let token = try await self.runtimeToken()
                            try await self.embeddedRuntime.waitUntilReady(token: token)
                            try Task.checkCancellation()
                            self.chat.runtimeBecameReady()
                            self.foregroundRuntime.setForegroundActive(true)
                            await self.setup.check()
                        } catch is CancellationError {
                            // iOS suspends this process; do not launch a second Node runtime on return.
                        } catch {
                            self.chat.runtimeFailed(EmbeddedRuntimeHost.Failure.unavailable.localizedDescription)
                        }
                    } else {
                        self.chat.runtimeDidSuspend()
                        self.foregroundRuntime.setForegroundActive(false)
                    }
                }
        }
    }
}
