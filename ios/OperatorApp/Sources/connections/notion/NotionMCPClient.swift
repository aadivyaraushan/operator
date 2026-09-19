import CryptoKit
import Foundation
import OperatorCore
import OSLog
import Security

struct NotionOAuthMetadata: Codable, Sendable, Equatable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
}

struct NotionAuthorizationRequest: Sendable, Equatable {
    let url: URL
    let state: String
}

enum NotionMCPError: Error, Equatable, Sendable {
    case invalidEndpoint
    case discoveryFailed
    case registrationFailed
    case invalidRegistration
    case callbackMismatch
    case tokenRequestFailed
    case missingTokens
    case credentialStoreCorrupt
    case protocolError(String)
    case httpFailure(Int)
}

enum NotionJSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: NotionJSONValue]), array([NotionJSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: NotionJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([NotionJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case let .string(v): try c.encode(v); case let .number(v): try c.encode(v); case let .bool(v): try c.encode(v); case let .object(v): try c.encode(v); case let .array(v): try c.encode(v); case .null: try c.encodeNil() }
    }
}

struct NotionTool: Codable, Equatable, Sendable { let name: String; let description: String? }

enum NotionRenewalDiagnostic: Equatable, Sendable {
    enum FailureCategory: String, Equatable, Sendable {
        case credentialLoad = "credential_load"
        case missingCredentials = "missing_credentials"
        case tokenRequest = "token_request"
        case missingAccessToken = "missing_access_token"
        case staleResult = "stale_result"
        case credentialSave = "credential_save"
    }

    case success
    case failure(FailureCategory)
}

actor NotionMCPClient {
    private struct Stored: Codable { var clientID: String?; var clientSecret: String?; var accessToken: String?; var refreshToken: String?; var expiresAt: Date?; var state: String?; var verifier: String?; var redirectURI: String? }
    private struct ProtectedResource: Codable { let authorizationServers: [URL]; enum CodingKeys: String, CodingKey { case authorizationServers = "authorization_servers" } }
    private struct RegistrationResponse: Codable { let clientID: String; let clientSecret: String?; enum CodingKeys: String, CodingKey { case clientID = "client_id"; case clientSecret = "client_secret" } }
    private struct TokenResponse: Codable { let accessToken: String; let refreshToken: String?; let expiresIn: Int?; enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token"; case expiresIn = "expires_in" } }
    private struct RPCResponse: Codable { let result: NotionJSONValue?; let error: RPCError?; let id: Int? }
    private struct RPCError: Codable { let code: Int; let message: String }
    private let serverURL = URL(string: "https://mcp.notion.com/mcp")!
    private let accountID: String
    private let store: any CredentialDataStore
    private let transport: any PhoneHTTPTransport
    private let randomBytes: @Sendable (Int) throws -> Data
    private let now: @Sendable () -> Date
    private let renewalDiagnostic: @Sendable (NotionRenewalDiagnostic) -> Void
    private let logger = Logger(subsystem: "app.operator.ios", category: "notion-renewal")
    private var sessionID: String?
    private var refreshInFlight: Task<Void, Error>?
    private var nextRequestID = 1

    init(accountID: String = "default", store: any CredentialDataStore, transport: any PhoneHTTPTransport, randomBytes: @escaping @Sendable (Int) throws -> Data = { count in var b = [UInt8](repeating: 0, count: count); guard SecRandomCopyBytes(kSecRandomDefault, count, &b) == errSecSuccess else { throw NotionMCPError.missingTokens }; return Data(b) }, now: @escaping @Sendable () -> Date = Date.init, renewalDiagnostic: @escaping @Sendable (NotionRenewalDiagnostic) -> Void = { _ in }) { self.accountID = accountID; self.store = store; self.transport = transport; self.randomBytes = randomBytes; self.now = now; self.renewalDiagnostic = renewalDiagnostic }

    func registeredRedirectURI() async throws -> String? { try await load().redirectURI }
    func configureLoopbackRedirectURI(_ value: String) async throws {
        guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.path == "/notion/callback", url.query == nil, url.fragment == nil
        else { throw NotionMCPError.callbackMismatch }
        var saved = try await load()
        if saved.clientID != nil, saved.redirectURI != value { throw NotionMCPError.invalidRegistration }
        if let existing = saved.redirectURI, existing != value { throw NotionMCPError.invalidRegistration }
        saved.redirectURI = value
        try await save(saved)
    }

    func discover() async throws -> NotionOAuthMetadata {
        let protectedURL = URL(string: "https://mcp.notion.com/.well-known/oauth-protected-resource")!
        let protected: ProtectedResource = try await get(protectedURL)
        guard let auth = protected.authorizationServers.first, Self.isAllowed(auth) else { throw NotionMCPError.invalidEndpoint }
        let metadataURL = auth.appendingPathComponent(".well-known/oauth-authorization-server")
        let raw: [String: NotionJSONValue] = try await get(metadataURL)
        guard case let .string(authEndpoint)? = raw["authorization_endpoint"], case let .string(tokenEndpoint)? = raw["token_endpoint"], let authorization = URL(string: authEndpoint), let token = URL(string: tokenEndpoint), Self.isAllowed(authorization), Self.isAllowed(token) else { throw NotionMCPError.discoveryFailed }
        let registration: URL? = if case let .string(value)? = raw["registration_endpoint"], let url = URL(string: value), Self.isAllowed(url) { url } else { nil }
        return .init(authorizationEndpoint: authorization, tokenEndpoint: token, registrationEndpoint: registration)
    }

    func register(metadata: NotionOAuthMetadata, clientName: String = "Operator iOS") async throws {
        try Self.validate(metadata); guard let endpoint = metadata.registrationEndpoint else { throw NotionMCPError.registrationFailed }
        let redirectURI = try await effectiveRedirectURI()
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": clientName, "redirect_uris": [redirectURI], "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"])
        let response: RegistrationResponse = try await send(request, as: RegistrationResponse.self)
        guard !response.clientID.isEmpty else { throw NotionMCPError.invalidRegistration }
        var saved = try await load(); saved.clientID = response.clientID; saved.clientSecret = response.clientSecret; try await save(saved)
    }

    func makeAuthorizationRequest(metadata: NotionOAuthMetadata) async throws -> NotionAuthorizationRequest {
        try Self.validate(metadata)
        let redirectURI = try await effectiveRedirectURI()
        let saved = try await load(); guard let clientID = saved.clientID else { throw NotionMCPError.invalidRegistration }
        let verifier = try randomString(32); let state = try randomString(32); var updated = saved; updated.state = state; updated.verifier = verifier; try await save(updated)
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!; components.queryItems = [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: verifier.s256), URLQueryItem(name: "code_challenge_method", value: "S256")]
        guard let url = components.url else { throw NotionMCPError.invalidEndpoint }; return .init(url: url, state: state)
    }

    func completeAuthorizationCallback(_ callback: URL, metadata: NotionOAuthMetadata) async throws {
        try Self.validate(metadata)
        let redirectURI = try await effectiveRedirectURI()
        let saved = try await load(); let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []; var query: [String: String] = [:]; for item in items { guard query[item.name] == nil, let value = item.value else { throw NotionMCPError.callbackMismatch }; query[item.name] = value }; guard Self.sameRedirect(callback, redirectURI), query["state"] == saved.state, let code = query["code"], let verifier = saved.verifier, let clientID = saved.clientID else { throw NotionMCPError.callbackMismatch }
        var request = URLRequest(url: metadata.tokenEndpoint); request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = form(["grant_type":"authorization_code", "code":code, "client_id":clientID, "redirect_uri":redirectURI, "code_verifier":verifier])
        let token: TokenResponse = try await send(request, as: TokenResponse.self); try Task.checkCancellation(); guard !token.accessToken.isEmpty, let refresh = token.refreshToken else { throw NotionMCPError.missingTokens }; var updated = saved; updated.accessToken = token.accessToken; updated.refreshToken = refresh; updated.expiresAt = now().addingTimeInterval(Double(token.expiresIn ?? 3600)); updated.state = nil; updated.verifier = nil; try await save(updated)
    }

    func refresh(metadata: NotionOAuthMetadata) async throws {
        try Self.validate(metadata)
        if let refreshInFlight { try await refreshInFlight.value; return }
        let task = Task { try await self.performRefresh(metadata: metadata) }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        try await task.value
    }

    private func performRefresh(metadata: NotionOAuthMetadata) async throws {
        let saved: Stored
        do { saved = try await load() }
        catch { emitRenewalFailure(.credentialLoad); throw error }
        guard let refresh = saved.refreshToken, let clientID = saved.clientID else {
            emitRenewalFailure(.missingCredentials)
            throw NotionMCPError.missingTokens
        }
        var request = URLRequest(url: metadata.tokenEndpoint); request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = form(["grant_type":"refresh_token", "refresh_token":refresh, "client_id":clientID])
        let token: TokenResponse
        do { token = try await send(request, as: TokenResponse.self) }
        catch { emitRenewalFailure(.tokenRequest); throw error }
        guard !token.accessToken.isEmpty else {
            emitRenewalFailure(.missingAccessToken)
            throw NotionMCPError.missingTokens
        }
        var latest: Stored
        do { latest = try await load() }
        catch { emitRenewalFailure(.credentialLoad); throw error }
        guard latest.refreshToken == refresh, latest.accessToken == saved.accessToken else {
            emitRenewalFailure(.staleResult)
            return
        }
        latest.accessToken = token.accessToken; latest.refreshToken = token.refreshToken ?? refresh; latest.expiresAt = now().addingTimeInterval(Double(token.expiresIn ?? 3600))
        do { try await save(latest) }
        catch { emitRenewalFailure(.credentialSave); throw error }
        logger.info("[notion-renewal] outcome=success category=saved")
        renewalDiagnostic(.success)
    }

    private func emitRenewalFailure(_ category: NotionRenewalDiagnostic.FailureCategory) {
        logger.error("[notion-renewal] outcome=failure category=\(category.rawValue, privacy: .public)")
        renewalDiagnostic(.failure(category))
    }

    func initialize() async throws -> NotionJSONValue { let result = try await rpc(method: "initialize", params: .object(["protocolVersion": .string("2025-03-26"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("Operator"), "version": .string("1.0")])])); try await notification(method: "notifications/initialized"); return result }
    func listTools() async throws -> NotionJSONValue { try await rpc(method: "tools/list", params: .object([:])) }
    func callTool(name: String, arguments: [String: NotionJSONValue]) async throws -> NotionJSONValue { try await rpc(method: "tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)])) }
    func hasRegistration() async throws -> Bool { try await load().clientID?.isEmpty == false }
    func restore() async throws { _ = try await validAccessToken() }

    private func effectiveRedirectURI() async throws -> String {
        let saved = try await load()
        let value = saved.redirectURI ?? ""
        guard !value.isEmpty else { throw NotionMCPError.invalidRegistration }
        return value
    }

    private func rpc(method: String, params: NotionJSONValue) async throws -> NotionJSONValue {
        let token = try await validAccessToken(); let requestID = nextRequestID; nextRequestID += 1
        var request = rpcRequest(token: token); request.httpBody = try JSONEncoder().encode(NotionJSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(requestID)), "method": .string(method), "params": params]))
        let (data, http) = try await rpcResponse(request); if let header = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = header }
        let responses: [RPCResponse]
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true { responses = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in guard line.hasPrefix("data:") else { return nil }; return try? JSONDecoder().decode(RPCResponse.self, from: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) } }
        else { responses = [try JSONDecoder().decode(RPCResponse.self, from: data)] }
        guard let decoded = responses.first(where: { $0.id == requestID }) else { throw NotionMCPError.protocolError("mismatched response id") }
        if let error = decoded.error { throw NotionMCPError.protocolError(error.message) }; guard let result = decoded.result else { throw NotionMCPError.protocolError("missing result") }; return result
    }

    private func notification(method: String) async throws {
        let token = try await validAccessToken(); var request = rpcRequest(token: token); request.httpBody = try JSONEncoder().encode(NotionJSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method)])); _ = try await rpcResponse(request)
    }
    private func validAccessToken() async throws -> String { var saved = try await load(); if let expiry = saved.expiresAt, expiry <= now() { try await refresh(metadata: try await discover()); saved = try await load() }; guard let token = saved.accessToken else { throw NotionMCPError.missingTokens }; return token }
    private func rpcRequest(token: String) -> URLRequest { var request = URLRequest(url: serverURL); request.httpMethod = "POST"; request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept"); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version"); if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }; return request }
    private func rpcResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { let (data, response) = try await transport.data(for: request); guard data.count <= 512_000 else { throw NotionMCPError.protocolError("response too large") }; guard let http = response as? HTTPURLResponse else { throw NotionMCPError.protocolError("invalid response") }; guard (200...299).contains(http.statusCode) else { throw NotionMCPError.httpFailure(http.statusCode) }; return (data, http) }

    private static func isAllowed(_ url: URL) -> Bool { url.scheme == "https" && ["mcp.notion.com", "api.notion.com"].contains(url.host?.lowercased()) && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil }
    private static func validate(_ metadata: NotionOAuthMetadata) throws { guard isAllowed(metadata.authorizationEndpoint), isAllowed(metadata.tokenEndpoint), metadata.registrationEndpoint.map(isAllowed) ?? true else { throw NotionMCPError.invalidEndpoint } }
    private static func sameRedirect(_ callback: URL, _ expected: String) -> Bool { guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false), let target = URLComponents(string: expected) else { return false }; return actual.scheme == target.scheme && actual.host == target.host && actual.port == target.port && actual.path == target.path }
    private func get<T: Decodable>(_ url: URL) async throws -> T { var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept"); return try await send(request, as: T.self) }
    private func send<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T { let (data, response) = try await transport.data(for: request); guard data.count <= 512_000 else { throw NotionMCPError.protocolError("response too large") }; guard let http = response as? HTTPURLResponse else { throw NotionMCPError.protocolError("invalid response") }; guard (200...299).contains(http.statusCode) else { throw NotionMCPError.httpFailure(http.statusCode) }; return try JSONDecoder().decode(T.self, from: data) }
    private func load() async throws -> Stored { guard let data = try await store.load() else { return Stored() }; do { return try JSONDecoder().decode(Stored.self, from: data) } catch { throw NotionMCPError.credentialStoreCorrupt } }
    private func save(_ value: Stored) async throws { try await store.save(JSONEncoder().encode(value)) }
    private func randomString(_ count: Int) throws -> String { Data(try randomBytes(count)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func form(_ values: [String: String]) -> Data { var c = URLComponents(); c.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }; return Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8) }
}

private extension String { var s256: String { Data(SHA256.hash(data: Data(utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
