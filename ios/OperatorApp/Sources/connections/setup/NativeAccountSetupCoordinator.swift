import AuthenticationServices
import Combine
import Foundation
import OperatorCore
import OSLog

struct OAuthClientOperations: Sendable { let begin: @Sendable () async throws -> OAuthAuthorizationRequest; let complete: @Sendable (URL) async throws -> OAuthTokens; let accessToken: @Sendable () async throws -> String }
@MainActor protocol OAuthSessionPresenting: AnyObject, Sendable { func authenticate(url: URL, callbackScheme: String?) async throws -> URL; func cancel() }
enum NativeAccountSetupState: Equatable { case idle, needsSetup, authorizing, connected, cancelled, failed }

enum OAuthSessionCancellation {
    static func normalized(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == ASWebAuthenticationSessionError.errorDomain,
              nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
        else { return error }
        return CancellationError()
    }
}

@MainActor final class NativeAccountSetupCoordinator: ObservableObject {
    @Published private(set) var activeProvider: OAuthProvider?
    @Published private(set) var states: [OAuthProvider: NativeAccountSetupState] = [:]
    private let registrations: [OAuthProvider: OAuthPublicClientRegistration]
    private let makeClient: @Sendable (OAuthProvider, OAuthPublicClientRegistration) -> OAuthClientOperations
    private let presenter: any OAuthSessionPresenting
    private var clients: [OAuthProvider: OAuthClientOperations] = [:]
    private var loopbackServer: LocalOAuthCallbackServer?
    private var task: Task<Void, Never>?; private var generation = 0
    private let logger = Logger(subsystem: "app.operator.ios", category: "account-setup")
    init(registrations: [OAuthProvider: OAuthPublicClientRegistration], presenter: any OAuthSessionPresenting, clients: @escaping @Sendable (OAuthProvider, OAuthPublicClientRegistration) -> OAuthClientOperations) {
        self.registrations = registrations; self.presenter = presenter; self.makeClient = clients
        for provider in OAuthProvider.allCases { states[provider] = registrations[provider]?.isValid == true ? .idle : .needsSetup }
    }
    convenience init(bundle: Bundle = .main, presenter: any OAuthSessionPresenting, keychainService: String = "app.operator.ios.oauth") {
        self.init(registrations: Self.registrations(bundle: bundle), presenter: presenter) { provider, registration in
            let store = KeychainCredentialStore(service: keychainService, account: provider.rawValue)
            let client = PhoneOAuthClient(provider: provider, registration: registration, accountID: provider.rawValue, store: store)
            return .init(begin: { try await client.makeAuthorizationRequest() }, complete: { try await client.completeAuthorizationCallback($0) }, accessToken: { try await client.accessToken() })
        }
    }
    func connect(_ provider: OAuthProvider) {
        guard task == nil else { return }
        guard let registration = registrations[provider], registration.isValid else { states[provider] = .needsSetup; return }
        let callbackScheme: String?
        if provider == .spotify {
            guard Self.spotifyLoopbackPort(registration.redirectURI) != nil else {
                logger.error("[account-setup] registration rejected provider=spotify loopback_shape=false")
                states[provider] = .needsSetup
                return
            }
            callbackScheme = nil
        } else {
            guard let scheme = URL(string: registration.redirectURI)?.scheme, !scheme.isEmpty else {
                states[provider] = .needsSetup
                return
            }
            callbackScheme = scheme
        }
        generation += 1; let run = generation; activeProvider = provider; states[provider] = .authorizing
        let client = client(for: provider, registration: registration)
        task = Task { [weak self, presenter] in
            do {
                guard let self else { throw CancellationError() }
                let server: LocalOAuthCallbackServer?
                if provider == .spotify {
                    guard let port = Self.spotifyLoopbackPort(registration.redirectURI) else {
                        throw PhoneOAuthError.missingRegistration
                    }
                    let prepared = LocalOAuthCallbackServer(path: "/spotify/callback", logTag: "spotify-loopback")
                    self.loopbackServer = prepared
                    let redirect = try await prepared.start(port: port)
                    guard redirect.absoluteString == registration.redirectURI else {
                        await prepared.cancel()
                        throw PhoneOAuthError.callbackRedirectMismatch
                    }
                    server = prepared
                    self.logger.info("[account-setup] authorization prepared provider=spotify callback=phone-local")
                } else {
                    server = nil
                    self.logger.info("[account-setup] authorization prepared provider=\(provider.rawValue, privacy: .public) callback=scheme")
                }
                let request = try await client.begin(); try Task.checkCancellation()
                let callback: URL
                if let server {
                    callback = try await LocalOAuthCallbackServer.receiveFirst(
                        server: server,
                        expectedState: request.state,
                        browser: { try await presenter.authenticate(url: request.url, callbackScheme: nil) },
                        cancelBrowser: { await presenter.cancel() })
                } else {
                    callback = try await presenter.authenticate(url: request.url, callbackScheme: callbackScheme)
                }
                try Task.checkCancellation()
                _ = try await client.complete(callback); try Task.checkCancellation()
                self.finish(provider, run: run, state: .connected)
            } catch is CancellationError {
                self?.finish(provider, run: run, state: .cancelled)
            } catch {
                self?.logger.error("[account-setup] authorization failed provider=\(provider.rawValue, privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                self?.finish(provider, run: run, state: .failed)
            }
        }
    }
    func cancel() {
        generation += 1
        presenter.cancel()
        task?.cancel()
        task = nil
        let server = loopbackServer
        loopbackServer = nil
        Task { await server?.cancel() }
        if let provider = activeProvider { states[provider] = .cancelled }
        activeProvider = nil
    }
    func accessToken(_ provider: OAuthProvider) async throws -> String { guard let registration = registrations[provider], registration.isValid else { throw PhoneOAuthError.missingRegistration }; return try await client(for: provider, registration: registration).accessToken() }
    func checkConnections() async {
        guard task == nil else { return }
        let run = generation
        logger.info("[account-setup] checking saved connections")
        for provider in OAuthProvider.allCases {
            guard let registration = registrations[provider], registration.isValid else { continue }
            let state: NativeAccountSetupState
            do {
                let token = try await client(for: provider, registration: registration).accessToken()
                state = token.isEmpty ? .idle : .connected
            } catch {
                logger.info("[account-setup] saved connection unavailable provider=\(provider.rawValue, privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                state = .idle
            }
            guard !Task.isCancelled, generation == run, task == nil else { return }
            states[provider] = state
            logger.info("[account-setup] saved connection checked provider=\(provider.rawValue, privacy: .public) connected=\(state == .connected)")
        }
    }
    func state(for provider: OAuthProvider) -> NativeAccountSetupState { states[provider] ?? .needsSetup }
    private func client(for provider: OAuthProvider, registration: OAuthPublicClientRegistration) -> OAuthClientOperations { if let cached = clients[provider] { return cached }; let made = makeClient(provider, registration); clients[provider] = made; return made }
    private func finish(_ provider: OAuthProvider, run: Int, state: NativeAccountSetupState) {
        guard generation == run else { return }
        states[provider] = state
        activeProvider = nil
        task = nil
        let server = loopbackServer
        loopbackServer = nil
        Task { await server?.cancel() }
        logger.info("[account-setup] authorization finished provider=\(provider.rawValue, privacy: .public) state=\(String(describing: state), privacy: .public)")
    }

    private static func spotifyLoopbackPort(_ redirectURI: String) -> UInt16? {
        guard let components = URLComponents(string: redirectURI),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.host == "127.0.0.1",
              let port = components.port.flatMap(UInt16.init(exactly:)),
              components.path == "/spotify/callback",
              components.percentEncodedQuery == nil,
              components.fragment == nil
        else { return nil }
        return port
    }
    static func registrations(bundle: Bundle) -> [OAuthProvider: OAuthPublicClientRegistration] {
        var result: [OAuthProvider: OAuthPublicClientRegistration] = [:]
        for provider in OAuthProvider.allCases {
            let suffix: String = switch provider { case .google: "GOOGLE"; case .microsoftOutlook: "MICROSOFT_OUTLOOK"; case .slack: "SLACK"; case .spotify: "SPOTIFY" }
            guard let id = bundle.object(forInfoDictionaryKey: "OPERATOR_OAUTH_\(suffix)_CLIENT_ID") as? String, let redirect = bundle.object(forInfoDictionaryKey: "OPERATOR_OAUTH_\(suffix)_REDIRECT_URI") as? String else { continue }
            let registration = OAuthPublicClientRegistration(clientID: id, redirectURI: redirect); if registration.isValid { result[provider] = registration }
        }
        return result
    }
}
