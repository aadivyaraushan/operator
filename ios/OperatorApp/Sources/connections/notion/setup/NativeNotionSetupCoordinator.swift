import Combine
import Foundation
import OSLog

enum NativeNotionSetupState: Equatable { case needsSetup, idle, authorizing, connected, cancelled, failed }

@MainActor final class NativeNotionSetupCoordinator: ObservableObject {
    @Published private(set) var state: NativeNotionSetupState
    let client: NotionMCPClient
    private let presenter: any OAuthSessionPresenting
    private var loopbackServer: NotionLoopbackCallbackServer?
    private var task: Task<Void,Never>?; private var generation = 0
    private let logger = Logger(subsystem: "app.operator.ios", category: "notion-setup")

    init(client: NotionMCPClient, presenter: any OAuthSessionPresenting) {
        self.client = client; self.presenter = presenter; self.state = .idle
    }
    convenience init(bundle: Bundle = .main, presenter: any OAuthSessionPresenting, transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport()) {
        let store = KeychainCredentialStore(service: "app.operator.ios.notion", account: "installation")
        self.init(client: NotionMCPClient(accountID: "installation", store: store, transport: transport), presenter: presenter)
    }
    func checkConnection() async {
        guard task == nil else { return }
        generation += 1
        let run = generation
        logger.info("[notion-setup] saved connection check started")
        let restoredState: NativeNotionSetupState
        let outcomeErrorCase: String?
        do {
            try await client.restore()
            restoredState = .connected
            outcomeErrorCase = nil
        } catch {
            restoredState = Self.restoredState(for: error)
            outcomeErrorCase = Self.errorCase(for: error)
        }
        guard !Task.isCancelled, generation == run, task == nil else { return }
        state = restoredState
        logger.info("[notion-setup] saved connection check applied state=\(String(describing: restoredState), privacy: .public) error_case=\((outcomeErrorCase ?? "none"), privacy: .public)")
    }
    func connect() {
        guard task == nil else { return }
        generation += 1; let run = generation; state = .authorizing
        task = Task { [weak self, client, presenter] in
            do {
                guard let self else { throw CancellationError() }
                let server = try await self.prepareCallback(client: client)
                let metadata = try await client.discover(); try Task.checkCancellation()
                if try await !client.hasRegistration() { try await client.register(metadata: metadata) }; try Task.checkCancellation()
                let request = try await client.makeAuthorizationRequest(metadata: metadata)
                let callback = try await Self.awaitLoopback(
                    server: server, presenter: presenter, request: request)
                try Task.checkCancellation()
                try await client.completeAuthorizationCallback(callback, metadata: metadata); try Task.checkCancellation(); _ = try await client.initialize(); try Task.checkCancellation()
                self.finish(run, .connected)
            } catch is CancellationError { self?.finish(run, .cancelled) } catch { self?.finish(run, .failed) }
        }
    }
    func cancel() { generation += 1; presenter.cancel(); task?.cancel(); task=nil; let server = loopbackServer; loopbackServer=nil; Task { await server?.cancel() }; state = .cancelled }
    private func finish(_ run:Int,_ value:NativeNotionSetupState) {
        guard generation == run else { return }
        state = value
        task = nil
        let server = loopbackServer
        loopbackServer = nil
        Task { await server?.cancel() }
    }

    private func prepareCallback(client: NotionMCPClient) async throws -> NotionLoopbackCallbackServer {
        let existing = try await client.registeredRedirectURI()
        let requestedPort = existing.flatMap { URL(string: $0)?.port }.flatMap(UInt16.init(exactly:))
        let server = NotionLoopbackCallbackServer()
        loopbackServer = server
        let redirect = try await server.start(port: requestedPort)
        try await client.configureLoopbackRedirectURI(redirect.absoluteString)
        return server
    }

    private static func awaitLoopback(
        server: NotionLoopbackCallbackServer,
        presenter: any OAuthSessionPresenting,
        request: NotionAuthorizationRequest
    ) async throws -> URL {
        try await LocalOAuthCallbackServer.receiveFirst(
            server: server,
            expectedState: request.state,
            browser: { try await presenter.authenticate(url: request.url, callbackScheme: nil) },
            cancelBrowser: { await presenter.cancel() })
    }

    private static func restoredState(for error: Error) -> NativeNotionSetupState {
        switch error {
        case NotionMCPError.missingTokens, NotionMCPError.credentialStoreCorrupt:
            .idle
        default:
            .failed
        }
    }

    private static func errorCase(for error: Error) -> String {
        switch error {
        case NotionMCPError.invalidEndpoint: "invalid_endpoint"
        case NotionMCPError.discoveryFailed: "discovery_failed"
        case NotionMCPError.registrationFailed: "registration_failed"
        case NotionMCPError.invalidRegistration: "invalid_registration"
        case NotionMCPError.callbackMismatch: "callback_mismatch"
        case NotionMCPError.tokenRequestFailed: "token_request_failed"
        case NotionMCPError.missingTokens: "missing_tokens"
        case NotionMCPError.credentialStoreCorrupt: "credential_store_corrupt"
        case NotionMCPError.protocolError: "protocol_error"
        case NotionMCPError.httpFailure: "http_failure"
        default: "other"
        }
    }
}
