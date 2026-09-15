import Foundation
import OperatorCore
import OSLog
import Security

actor PhoneOAuthClient {
    private static let refreshLeeway: TimeInterval = 60
    private struct PendingAuthorization: Codable, Sendable {
        let state: String
        let codeVerifier: String
    }

    private struct StoredConnection: Codable, Sendable {
        let provider: OAuthProvider
        let accountID: String
        var pending: PendingAuthorization?
        var tokens: OAuthTokens?
    }

    private let provider: OAuthProvider
    private let registration: OAuthPublicClientRegistration
    private let accountID: String
    private let store: any CredentialDataStore
    private let transport: any PhoneHTTPTransport
    private let randomBytes: @Sendable (Int) throws -> Data
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "phone-oauth")
    private var refreshInFlight: Task<OAuthTokens, Error>?

    init(
        provider: OAuthProvider,
        registration: OAuthPublicClientRegistration,
        accountID: String,
        store: any CredentialDataStore,
        transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport(),
        randomBytes: @escaping @Sendable (Int) throws -> Data = { count in
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
                throw PhoneOAuthError.randomGenerationFailed
            }
            return Data(bytes)
        },
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.provider = provider
        self.registration = registration
        self.accountID = accountID
        self.store = store
        self.transport = transport
        self.randomBytes = randomBytes
        self.now = now
    }

    func makeAuthorizationRequest() async throws -> OAuthAuthorizationRequest {
        try self.validateSetup()
        let verifier = try self.randomString(byteCount: 64)
        let state = try self.randomString(byteCount: 32)
        var connection = try await self.loadConnection() ?? .init(provider: self.provider, accountID: self.accountID, pending: nil, tokens: nil)
        connection.pending = .init(state: state, codeVerifier: verifier)
        try await self.saveConnection(connection)
        self.logger.info("[phone-oauth] authorization ready provider=\(self.provider.rawValue, privacy: .public) scopeCount=\(self.provider.scopes.count)")
        return .init(url: try self.authorizationURL(state: state, verifier: verifier), state: state, codeVerifier: verifier)
    }

    func completeAuthorizationCallback(_ callback: URL) async throws -> OAuthTokens {
        do { return try await self.performAuthorizationCallback(callback) }
        catch {
            let errorCode = (error as? PhoneOAuthError)?.rawValue ?? "unexpected"
            self.logger.error("[phone-oauth] callback failed provider=\(self.provider.rawValue, privacy: .public) errorCode=\(errorCode, privacy: .public)")
            throw error
        }
    }

    private func performAuthorizationCallback(_ callback: URL) async throws -> OAuthTokens {
        try self.validateSetup()
        try self.validateCallbackRedirect(callback)
        let query = try self.callbackQuery(callback)
        guard let state = query["state"], !state.isEmpty else { throw PhoneOAuthError.callbackStateMismatch }
        guard var connection = try await self.loadConnection(), let pending = connection.pending else {
            throw PhoneOAuthError.missingPendingAuthorization
        }
        guard state == pending.state else { throw PhoneOAuthError.callbackStateMismatch }
        connection.pending = nil
        try await self.saveConnection(connection)
        guard query["error"] == nil else {
            // Log only standard error names and Microsoft's numeric support code,
            // never the callback, description, account details or credentials.
            let standardErrors = ["access_denied", "invalid_request", "unauthorized_client", "unsupported_response_type", "invalid_scope", "server_error", "temporarily_unavailable", "login_required", "interaction_required", "consent_required"]
            let reason = standardErrors.first(where: { $0 == query["error"] }) ?? "other"
            let description = query["error_description"] ?? ""
            let codeRange = description.range(of: "AADSTS[0-9]{4,12}", options: .regularExpression)
            let supportCode = codeRange.map { String(description[$0]) } ?? "none"
            self.logger.info("[phone-oauth] authorization denied provider=\(self.provider.rawValue, privacy: .public) reason=\(reason, privacy: .public) supportCode=\(supportCode, privacy: .public)")
            throw PhoneOAuthError.authorizationDenied
        }
        guard let code = query["code"], !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneOAuthError.missingAuthorizationCode
        }
        let tokens = try await self.exchange(
            form: [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": self.registration.redirectURI, "client_id": self.registration.clientID,
                "code_verifier": pending.codeVerifier,
            ], previous: connection.tokens)
        // A provider reply may arrive after the owner cancelled the browser flow.
        // Do not turn that cancelled attempt into a saved connection.
        try Task.checkCancellation()
        connection.tokens = tokens
        try await self.saveConnection(connection)
        self.logger.info("[phone-oauth] authorization stored provider=\(self.provider.rawValue, privacy: .public) scopeCount=\(tokens.grantedScopes.count)")
        return tokens
    }

    func refresh() async throws -> OAuthTokens {
        try self.validateSetup()
        if let refreshInFlight { return try await refreshInFlight.value }
        let task = Task { try await self.refreshStoredTokens() }
        self.refreshInFlight = task
        defer { self.refreshInFlight = nil }
        return try await task.value
    }

    func accessToken() async throws -> String {
        try self.validateSetup()
        guard let tokens = try await self.loadConnection()?.tokens else { throw PhoneOAuthError.notConnected }
        guard Set(self.provider.requiredAccessTokenScopes).isSubset(of: Set(tokens.grantedScopes)) else {
            self.logger.info("[phone-oauth] saved authorization needs renewal provider=\(self.provider.rawValue, privacy: .public) errorCode=\(PhoneOAuthError.reauthorizationRequired.rawValue, privacy: .public)")
            throw PhoneOAuthError.reauthorizationRequired
        }
        guard tokens.expiresAt > self.now().addingTimeInterval(Self.refreshLeeway) else {
            return try await self.refresh().accessToken
        }
        return tokens.accessToken
    }

    func storeForTesting(_ tokens: OAuthTokens) async throws {
        try await self.saveConnection(.init(provider: self.provider, accountID: self.accountID, pending: nil, tokens: tokens))
    }

    private func refreshStoredTokens() async throws -> OAuthTokens {
        guard var connection = try await self.loadConnection(), let previous = connection.tokens else {
            throw PhoneOAuthError.notConnected
        }
        let tokens = try await self.exchange(
            form: ["grant_type": "refresh_token", "refresh_token": previous.refreshToken, "client_id": self.registration.clientID],
            previous: previous)
        connection.tokens = tokens
        try await self.saveConnection(connection)
        self.logger.info("[phone-oauth] token refreshed provider=\(self.provider.rawValue, privacy: .public)")
        return tokens
    }

    private func validateSetup() throws {
        guard self.registration.isValid else { throw PhoneOAuthError.missingRegistration }
        guard !self.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneOAuthError.invalidAccountID }
    }

    private func authorizationURL(state: String, verifier: String) throws -> URL {
        var components = URLComponents(url: self.provider.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "client_id", value: self.registration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: self.registration.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: verifier.s256Challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if self.provider == .slack {
            query.append(.init(name: "user_scope", value: self.provider.scopes.joined(separator: ",")))
        } else {
            query.append(.init(name: "scope", value: self.provider.scopes.joined(separator: " ")))
        }
        for (name, value) in self.provider.authorizationParameters.sorted(by: { $0.key < $1.key }) {
            query.append(.init(name: name, value: value))
        }
        components.queryItems = query
        guard let url = components.url else { throw PhoneOAuthError.missingRegistration }
        return url
    }

    private func validateCallbackRedirect(_ callback: URL) throws {
        guard let expected = URLComponents(string: self.registration.redirectURI),
              let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              expected.scheme == actual.scheme,
              expected.user == actual.user,
              expected.password == actual.password,
              expected.host == actual.host,
              expected.port == actual.port,
              (expected.path == actual.path
                || (self.provider == .microsoftOutlook && expected.host != nil
                    && expected.path.isEmpty && actual.path == "/"))
        else { throw PhoneOAuthError.callbackRedirectMismatch }
        // Microsoft appends a slash to redirects with no path in query/fragment
        // responses. Keep the originally registered URI for the token exchange.
        if expected.path != actual.path {
            self.logger.info("[phone-oauth] accepted documented root slash provider=\(self.provider.rawValue, privacy: .public)")
        }
        let expectedItems = expected.queryItems ?? []
        let actualItems = actual.queryItems ?? []
        for item in expectedItems where !actualItems.contains(item) {
            throw PhoneOAuthError.callbackRedirectMismatch
        }
    }

    private func callbackQuery(_ callback: URL) throws -> [String: String] {
        let expected = URLComponents(string: self.registration.redirectURI)?.queryItems ?? []
        let allowed = Set(expected.map(\.name)).union(["code", "state", "error", "error_description"])
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        for item in items where allowed.contains(item.name) {
            guard query[item.name] == nil, let value = item.value else {
                throw PhoneOAuthError.callbackRedirectMismatch
            }
            query[item.name] = value
        }
        return query
    }

    private func exchange(form: [String: String], previous: OAuthTokens?) async throws -> OAuthTokens {
        var request = URLRequest(url: self.provider.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodedForm(form)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await self.transport.data(for: request) }
        catch { throw PhoneOAuthError.tokenRequestFailed }
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw PhoneOAuthError.tokenRequestFailed
        }
        return try self.parseTokens(data, previous: previous)
    }

    private func parseTokens(_ data: Data, previous: OAuthTokens?) throws -> OAuthTokens {
        if self.provider == .slack {
            let slack = try? JSONDecoder().decode(SlackTokenResponse.self, from: data)
            guard slack?.ok == true else { throw PhoneOAuthError.invalidTokenResponse }
            let refreshedUser = previous == nil ? nil : try? JSONDecoder().decode(SlackTokenResponse.AuthedUser.self, from: data)
            guard let user = slack?.authedUser ?? refreshedUser, user.tokenType == "user" else {
                throw PhoneOAuthError.invalidTokenResponse
            }
            return try self.validTokens(
                accessToken: user.accessToken, refreshToken: user.refreshToken,
                expiresIn: user.expiresIn, scope: user.scope, previous: previous)
        }
        let response = try? JSONDecoder().decode(TokenResponse.self, from: data)
        return try self.validTokens(
            accessToken: response?.accessToken, refreshToken: response?.refreshToken,
            expiresIn: response?.expiresIn, scope: response?.scope, previous: previous)
    }

    private func validTokens(
        accessToken: String?, refreshToken: String?, expiresIn: Int?, scope: String?, previous: OAuthTokens?) throws -> OAuthTokens
    {
        guard let accessToken, !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expiresIn, (1 ... 31_536_000).contains(expiresIn)
        else { throw PhoneOAuthError.invalidTokenResponse }
        let refresh = refreshToken ?? previous?.refreshToken
        guard let refresh, !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneOAuthError.invalidTokenResponse
        }
        let granted = scope?.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) ?? previous?.grantedScopes ?? []
        guard Set(self.provider.requiredAccessTokenScopes).isSubset(of: Set(granted)) else { throw PhoneOAuthError.invalidTokenResponse }
        return .init(accessToken: accessToken, refreshToken: refresh, expiresAt: self.now().addingTimeInterval(Double(expiresIn)), grantedScopes: granted.sorted())
    }

    // Each actor receives a Keychain store dedicated to this provider/account pair.
    // CredentialDataStore has no merge operation, so sharing one store across actors
    // could overwrite a concurrent connection update.
    private func loadConnection() async throws -> StoredConnection? {
        let stored: Data?
        do { stored = try await self.store.load() }
        catch {
            self.logger.error("[phone-oauth] credential load failed provider=\(self.provider.rawValue, privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
        guard let data = stored else { return nil }
        guard let connection = try? JSONDecoder().decode(StoredConnection.self, from: data) else {
            self.logger.error("[phone-oauth] stored credentials were corrupt")
            throw PhoneOAuthError.credentialStoreCorrupt
        }
        guard connection.provider == self.provider, connection.accountID == self.accountID else {
            self.logger.error("[phone-oauth] stored credential identity mismatch provider=\(self.provider.rawValue, privacy: .public)")
            throw PhoneOAuthError.notConnected
        }
        return connection
    }

    private func saveConnection(_ connection: StoredConnection) async throws {
        do { try await self.store.save(JSONEncoder().encode(connection)) }
        catch {
            self.logger.error("[phone-oauth] credential save failed provider=\(self.provider.rawValue, privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
    }

    private func randomString(byteCount: Int) throws -> String {
        let bytes = try self.randomBytes(byteCount)
        guard bytes.count == byteCount else { throw PhoneOAuthError.randomGenerationFailed }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func encodedForm(_ form: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope
    }
}

private struct SlackTokenResponse: Decodable {
    struct AuthedUser: Decodable {
        let accessToken: String
        let tokenType: String
        let refreshToken: String?
        let expiresIn: Int
        let scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", tokenType = "token_type", refreshToken = "refresh_token", expiresIn = "expires_in", scope
        }
    }
    let ok: Bool
    let authedUser: AuthedUser?
    enum CodingKeys: String, CodingKey {
        case ok, authedUser = "authed_user"
    }
}
