import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

final class NotionMCPClientTests: XCTestCase {
    func testRefreshLogsSuccessOnlyAfterCredentialsAreSaved() async throws {
        let store = SaveObservingStore(initial: #"{"clientID":"c","accessToken":"old","refreshToken":"r"}"#)
        let events = RenewalEventRecorder()
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/token", #"{"access_token":"fresh","refresh_token":"r2","expires_in":60}"#)])
        let client = NotionMCPClient(store: store, transport: transport, renewalDiagnostic: { event in
            Task { await events.record(event, savedAtEmission: await store.didSave) }
        })

        try await client.refresh(metadata: notionMetadata)
        let recorded = await events.waitForCount(1)

        XCTAssertEqual(recorded.map(\.event), [.success])
        XCTAssertEqual(recorded.map(\.savedAtEmission), [true])
    }

    func testRefreshLogsSafeFailureWithoutSuccessWhenResponseLacksAccessToken() async {
        let events = RenewalEventRecorder()
        let store = SaveObservingStore(initial: #"{"clientID":"c","accessToken":"old","refreshToken":"r"}"#)
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/token", #"{"access_token":"","refresh_token":"do-not-log"}"#)])
        let client = NotionMCPClient(store: store, transport: transport, renewalDiagnostic: { event in
            Task { await events.record(event, savedAtEmission: await store.didSave) }
        })

        await XCTAssertThrowsErrorAsync(try await client.refresh(metadata: notionMetadata)) {
            XCTAssertEqual($0 as? NotionMCPError, .missingTokens)
        }

        let recorded = await events.waitForCount(1)
        XCTAssertEqual(recorded.map(\.event), [.failure(.missingAccessToken)])
    }

    func testRefreshLogsSafeFailureWithoutSuccessWhenCredentialSaveFails() async {
        let events = RenewalEventRecorder()
        let store = SaveObservingStore(initial: #"{"clientID":"c","accessToken":"old","refreshToken":"r"}"#, failSave: true)
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/token", #"{"access_token":"fresh","refresh_token":"r2"}"#)])
        let client = NotionMCPClient(store: store, transport: transport, renewalDiagnostic: { event in
            Task { await events.record(event, savedAtEmission: await store.didSave) }
        })

        await XCTAssertThrowsErrorAsync(try await client.refresh(metadata: notionMetadata)) { _ in }

        let recorded = await events.waitForCount(1)
        XCTAssertEqual(recorded.map(\.event), [.failure(.credentialSave)])
    }

    func testPhoneTransportDoesNotFollowRedirects() async {
        URLProtocol.registerClass(RedirectProtocol.self)
        defer { URLProtocol.unregisterClass(RedirectProtocol.self) }
        var request = URLRequest(url: URL(string: "https://redirect.operator.invalid")!)
        request.httpMethod = "GET"
        do { _ = try await URLSessionPhoneHTTPTransport().data(for: request); XCTFail("redirect should be rejected") } catch { XCTAssertTrue(error is URLError) }
    }

    func testDiscoveryUsesProtectedResourceAndRejectsUntrustedAuthorizationServer() async throws {
        let transport = FixtureTransport(responses: [
            ("https://mcp.notion.com/.well-known/oauth-protected-resource", #"{"authorization_servers":["https://evil.example"]}"#)
        ])
        let client = NotionMCPClient(store: MemoryStore(), transport: transport)
        await XCTAssertThrowsErrorAsync(try await client.discover()) { XCTAssertEqual($0 as? NotionMCPError, .invalidEndpoint) }
    }

    func testInitializeSendsBearerProtocolAndSessionHeadersAndAcceptsSSE() async throws {
        let store = MemoryStore(); await store.set(#"{"clientID":"c","accessToken":"a"}"#)
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/mcp", #"""
data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}

"""#)], contentType: "text/event-stream", sessionID: "session-1")
        let client = NotionMCPClient(store: store, transport: transport)
        _ = try await client.initialize()
        let requests = await transport.requests
        let request = requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-03-26")
        let responseSessionID = transport.responseSessionID
        XCTAssertEqual(responseSessionID, "session-1")
    }

    func testCallbackOriginAndStateAreBothRequired() async throws {
        let store = MemoryStore(); await store.set(#"{"clientID":"c","state":"s","verifier":"v","redirectURI":"http://127.0.0.1:49152/notion/callback"}"#)
        let client = NotionMCPClient(store: store, transport: FixtureTransport(responses: []))
        let metadata = NotionOAuthMetadata(authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!, tokenEndpoint: URL(string: "https://mcp.notion.com/token")!, registrationEndpoint: nil)
        await XCTAssertThrowsErrorAsync(try await client.completeAuthorizationCallback(URL(string: "http://127.0.0.1:49153/notion/callback?code=c&state=s")!, metadata: metadata)) { XCTAssertEqual($0 as? NotionMCPError, .callbackMismatch) }
        await XCTAssertThrowsErrorAsync(try await client.completeAuthorizationCallback(URL(string: "http://127.0.0.1:49152/notion/callback?code=c&state=wrong")!, metadata: metadata)) { XCTAssertEqual($0 as? NotionMCPError, .callbackMismatch) }
    }

    func testWrongRPCIDAndJSONRPCErrorAreRejected() async throws {
        let store = MemoryStore(); await store.set(#"{"accessToken":"a"}"#)
        let wrongID = NotionMCPClient(store: store, transport: FixtureTransport(responses: [("https://mcp.notion.com/mcp", #"{"jsonrpc":"2.0","id":99,"result":{}}"#)]))
        await XCTAssertThrowsErrorAsync(try await wrongID.initialize()) { XCTAssertEqual($0 as? NotionMCPError, .protocolError("mismatched response id")) }
        let rpcError = NotionMCPClient(store: store, transport: FixtureTransport(responses: [("https://mcp.notion.com/mcp", #"{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"denied"}}"#)]))
        await XCTAssertThrowsErrorAsync(try await rpcError.initialize()) { XCTAssertEqual($0 as? NotionMCPError, .protocolError("denied")) }
    }

    func testConcurrentRefreshUsesOneHTTPRequestAndMissingTokenIsNotConnected() async throws {
        let store = MemoryStore(); await store.set(#"{"clientID":"c","refreshToken":"r"}"#)
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/token", #"{"access_token":"a","refresh_token":"r2","expires_in":60}"#)])
        let client = NotionMCPClient(store: store, transport: transport)
        let metadata = NotionOAuthMetadata(authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!, tokenEndpoint: URL(string: "https://mcp.notion.com/token")!, registrationEndpoint: nil)
        async let first: Void = client.refresh(metadata: metadata); async let second: Void = client.refresh(metadata: metadata); _ = try await (first, second)
        let requestCount = await transport.count
        XCTAssertEqual(requestCount, 1)
        let empty = NotionMCPClient(store: MemoryStore(), transport: transport)
        await XCTAssertThrowsErrorAsync(try await empty.initialize()) { XCTAssertEqual($0 as? NotionMCPError, .missingTokens) }
    }

    func testDuplicateCallbackQueryIsRejectedWithoutCrashOrHTTP() async throws {
        let store = MemoryStore(); await store.set(#"{"clientID":"c","state":"s","verifier":"v","redirectURI":"http://127.0.0.1:49152/notion/callback"}"#)
        let transport = FixtureTransport(responses: [])
        let client = NotionMCPClient(store: store, transport: transport)
        let metadata = NotionOAuthMetadata(authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!, tokenEndpoint: URL(string: "https://mcp.notion.com/token")!, registrationEndpoint: nil)
        await XCTAssertThrowsErrorAsync(try await client.completeAuthorizationCallback(URL(string: "http://127.0.0.1:49152/notion/callback?code=a&code=b&state=s")!, metadata: metadata)) { XCTAssertEqual($0 as? NotionMCPError, .callbackMismatch) }
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }

    func testUntrustedMetadataEndpointIsRejectedBeforeHTTP() async throws {
        let client = NotionMCPClient(store: MemoryStore(), transport: FixtureTransport(responses: []))
        let bad = NotionOAuthMetadata(authorizationEndpoint: URL(string: "https://evil.example/auth")!, tokenEndpoint: URL(string: "https://evil.example/token")!, registrationEndpoint: URL(string: "https://evil.example/register"))
        await XCTAssertThrowsErrorAsync(try await client.register(metadata: bad)) { XCTAssertEqual($0 as? NotionMCPError, .invalidEndpoint) }
        await XCTAssertThrowsErrorAsync(try await client.makeAuthorizationRequest(metadata: bad)) { XCTAssertEqual($0 as? NotionMCPError, .invalidEndpoint) }
    }

    func testCorruptStoredCredentialsAreNotSilentlyErased() async {
        let store = MemoryStore(); await store.set("not-json")
        let client = NotionMCPClient(store: store, transport: FixtureTransport(responses: []))
        await XCTAssertThrowsErrorAsync(try await client.initialize()) { XCTAssertEqual($0 as? NotionMCPError, .credentialStoreCorrupt) }
    }

    func testInitializeSendsNotificationThenUsesUniqueRequestIDAndMatchingSSEEvent() async throws {
        let store = MemoryStore(); await store.set(#"{"accessToken":"a"}"#)
        let stream = "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n"
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/mcp", stream), ("https://mcp.notion.com/mcp", "{}"), ("https://mcp.notion.com/mcp", "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}\n")], contentType: "text/event-stream")
        let client = NotionMCPClient(store: store, transport: transport)
        // `NotionMCPClient` has two `listTools()` overloads (the raw MCP one
        // here, plus the `NotionNodeClient` `[NotionTool]` one). Name the
        // return type so the discarded call is not ambiguous.
        _ = try await client.initialize()
        let _: NotionJSONValue = try await client.listTools()
        let bodies = await transport.requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String:Any] } }
        XCTAssertEqual(bodies[0]["id"] as? Int, 1); XCTAssertEqual(bodies[1]["method"] as? String, "notifications/initialized"); XCTAssertNil(bodies[1]["id"]); XCTAssertEqual(bodies[2]["id"] as? Int, 2)
    }

    func testExpiredRPCTokenDiscoversAndRefreshesBeforeInitialize() async throws {
        let store = MemoryStore(); await store.set(#"{"clientID":"c","accessToken":"old","refreshToken":"r","expiresAt":0}"#)
        let transport = FixtureTransport(responses: [
            ("https://mcp.notion.com/.well-known/oauth-protected-resource", #"{"authorization_servers":["https://mcp.notion.com"]}"#),
            ("https://mcp.notion.com/.well-known/oauth-authorization-server", #"{"authorization_endpoint":"https://mcp.notion.com/authorize","token_endpoint":"https://mcp.notion.com/token"}"#),
            ("https://mcp.notion.com/token", #"{"access_token":"fresh","refresh_token":"r","expires_in":3600}"#),
            ("https://mcp.notion.com/mcp", #"{"jsonrpc":"2.0","id":1,"result":{}}"#), ("https://mcp.notion.com/mcp", "{}")])
        let client = NotionMCPClient(store: store, transport: transport, now: { Date(timeIntervalSinceReferenceDate: 100) })
        _ = try await client.initialize()
        let requests = await transport.requests; XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testDelayedRefreshPreservesNewAuthorizationStateAndCompletedCredentials() async throws {
        let store = MemoryStore()
        await store.set(#"{"clientID":"client","accessToken":"old-access","refreshToken":"old-refresh","expiresAt":0,"redirectURI":"http://127.0.0.1:49152/notion/callback"}"#)
        let transport = DelayedRefreshTransport()
        let client = NotionMCPClient(store: store, transport: transport)
        let metadata = NotionOAuthMetadata(
            authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!,
            tokenEndpoint: URL(string: "https://mcp.notion.com/token")!,
            registrationEndpoint: nil)

        let restoration = Task { try await client.restore() }
        while !(await transport.isRefreshWaiting) { await Task.yield() }
        let request = try await client.makeAuthorizationRequest(metadata: metadata)
        let callback = URL(string: "http://127.0.0.1:49152/notion/callback?code=authorization-code&state=\(request.state)")!
        try await client.completeAuthorizationCallback(callback, metadata: metadata)
        await transport.releaseRefresh()
        try await restoration.value

        let savedData = try await store.load()
        let saved = String(decoding: try XCTUnwrap(savedData), as: UTF8.self)
        XCTAssertTrue(saved.contains("authorized-access"))
        XCTAssertTrue(saved.contains("authorized-refresh"))
        XCTAssertFalse(saved.contains("refreshed-access"))
    }

    func testStaleConcurrentRefreshLogsIgnoredFailureWithoutSuccess() async throws {
        let store = MemoryStore()
        await store.set(#"{"clientID":"client","accessToken":"old-access","refreshToken":"old-refresh","expiresAt":0,"redirectURI":"http://127.0.0.1:49152/notion/callback"}"#)
        let transport = DelayedRefreshTransport()
        let events = RenewalEventRecorder()
        let client = NotionMCPClient(store: store, transport: transport, renewalDiagnostic: { event in
            Task { await events.record(event, savedAtEmission: true) }
        })

        let restoration = Task { try await client.restore() }
        while !(await transport.isRefreshWaiting) { await Task.yield() }
        let request = try await client.makeAuthorizationRequest(metadata: notionMetadata)
        let callback = URL(string: "http://127.0.0.1:49152/notion/callback?code=authorization-code&state=\(request.state)")!
        try await client.completeAuthorizationCallback(callback, metadata: notionMetadata)
        await transport.releaseRefresh()
        try await restoration.value

        let recorded = await events.waitForCount(1)
        XCTAssertEqual(recorded.map(\.event), [.failure(.staleResult)])
    }

    func testAuthorizationCodePlusIsPercentEncodedAndOversizedResponseRejected() async throws {
        let store = MemoryStore(); await store.set(#"{"clientID":"c","state":"s","verifier":"v","redirectURI":"http://127.0.0.1:49152/notion/callback"}"#)
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/token", #"{"access_token":"a","refresh_token":"r"}"#)])
        let client = NotionMCPClient(store: store, transport: transport)
        let metadata = NotionOAuthMetadata(authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!, tokenEndpoint: URL(string: "https://mcp.notion.com/token")!, registrationEndpoint: nil)
        try await client.completeAuthorizationCallback(URL(string: "http://127.0.0.1:49152/notion/callback?code=a%2Bb&state=s")!, metadata: metadata)
        let body = String(data: await transport.requests[0].httpBody!, encoding: .utf8)!; XCTAssertTrue(body.contains("code=a%2Bb")); XCTAssertFalse(body.contains("code=a+b"))
        let huge = FixtureTransport(responses: [("https://mcp.notion.com/mcp", String(repeating: "x", count: 512_001))]); let hugeClient = NotionMCPClient(store: store, transport: huge)
        await XCTAssertThrowsErrorAsync(try await hugeClient.initialize()) { XCTAssertEqual($0 as? NotionMCPError, .protocolError("response too large")) }
    }

    func testCancelledCallbackDoesNotSaveReturnedTokens() async throws {
        let store = MemoryStore(); await store.set(#"{"clientID":"c","state":"s","verifier":"v","redirectURI":"http://127.0.0.1:49152/notion/callback"}"#)
        let transport = CancellationIgnoringTransport()
        let client = NotionMCPClient(store: store, transport: transport)
        let metadata = NotionOAuthMetadata(authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!, tokenEndpoint: URL(string: "https://mcp.notion.com/token")!, registrationEndpoint: nil)
        let task = Task { try await client.completeAuthorizationCallback(URL(string: "http://127.0.0.1:49152/notion/callback?code=c&state=s")!, metadata: metadata) }
        while !(await transport.isWaiting) { await Task.yield() }
        task.cancel(); await transport.release()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let storedData = try await store.load()
        let saved = String(decoding: try XCTUnwrap(storedData), as: UTF8.self)
        XCTAssertFalse(saved.contains("accessToken"))
    }

    func testLoopbackRedirectIsPersistedAndCannotChangeAfterRegistration() async throws {
        let store = MemoryStore()
        let transport = FixtureTransport(responses: [("https://mcp.notion.com/register", #"{"client_id":"registered"}"#)])
        let client = NotionMCPClient(store: store, transport: transport)
        try await client.configureLoopbackRedirectURI("http://127.0.0.1:49152/notion/callback")
        let metadata = NotionOAuthMetadata(
            authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!,
            tokenEndpoint: URL(string: "https://mcp.notion.com/token")!,
            registrationEndpoint: URL(string: "https://mcp.notion.com/register")!)
        try await client.register(metadata: metadata)
        let requests = await transport.requests
        let body = try XCTUnwrap(requests.first?.httpBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("http:\\/\\/127.0.0.1:49152\\/notion\\/callback"))
        await XCTAssertThrowsErrorAsync(try await client.configureLoopbackRedirectURI("http://127.0.0.1:49153/notion/callback")) {
            XCTAssertEqual($0 as? NotionMCPError, .invalidRegistration)
        }
        let persisted = try await client.registeredRedirectURI()
        XCTAssertEqual(persisted, "http://127.0.0.1:49152/notion/callback")
    }
}

private let notionMetadata = NotionOAuthMetadata(
    authorizationEndpoint: URL(string: "https://mcp.notion.com/authorize")!,
    tokenEndpoint: URL(string: "https://mcp.notion.com/token")!,
    registrationEndpoint: nil)

private actor RenewalEventRecorder {
    struct Entry: Sendable { let event: NotionRenewalDiagnostic; let savedAtEmission: Bool }
    private var entries: [Entry] = []
    func record(_ event: NotionRenewalDiagnostic, savedAtEmission: Bool) { entries.append(.init(event: event, savedAtEmission: savedAtEmission)) }
    func waitForCount(_ count: Int) async -> [Entry] {
        while entries.count < count { await Task.yield() }
        return entries
    }
}

private actor SaveObservingStore: CredentialDataStore {
    enum Failure: Error { case refused }
    private var value: Data?
    private let failSave: Bool
    private(set) var didSave = false
    init(initial: String, failSave: Bool = false) { value = Data(initial.utf8); self.failSave = failSave }
    func load() async throws -> Data? { value }
    func save(_ data: Data) async throws {
        if failSave { throw Failure.refused }
        value = data
        didSave = true
    }
}

private actor MemoryStore: CredentialDataStore {
    var value: Data?
    func load() async throws -> Data? { value }
    func save(_ data: Data) async throws { value = data }
    func set(_ value: String) { self.value = Data(value.utf8) }
}

private actor FixtureTransport: PhoneHTTPTransport {
    let responses: [(String, String)]; let contentType: String; let responseSessionID: String?
    var requests: [URLRequest] = []
    var count: Int { requests.count }
    init(responses: [(String, String)], contentType: String = "application/json", sessionID: String? = nil) { self.responses = responses; self.contentType = contentType; self.responseSessionID = sessionID }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { let prior = requests.filter { $0.url == request.url }.count; requests.append(request); let matches = responses.filter { $0.0 == request.url?.absoluteString }; let match = matches.isEmpty ? responses[0] : matches[min(prior, matches.count - 1)]; var headers = ["Content-Type": contentType]; if let responseSessionID { headers["Mcp-Session-Id"] = responseSessionID }; return (Data(match.1.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!) }
}

private actor CancellationIgnoringTransport: PhoneHTTPTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await withCheckedContinuation { continuation = $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(#"{"access_token":"late","refresh_token":"late-refresh"}"#.utf8), response)
    }
}

private actor DelayedRefreshTransport: PhoneHTTPTransport {
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var tokenRequests = 0
    var isRefreshWaiting: Bool { refreshContinuation != nil }

    func releaseRefresh() { refreshContinuation?.resume(); refreshContinuation = nil }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url?.absoluteString)
        let body: String
        switch url {
        case "https://mcp.notion.com/.well-known/oauth-protected-resource":
            body = #"{"authorization_servers":["https://mcp.notion.com"]}"#
        case "https://mcp.notion.com/.well-known/oauth-authorization-server":
            body = #"{"authorization_endpoint":"https://mcp.notion.com/authorize","token_endpoint":"https://mcp.notion.com/token"}"#
        case "https://mcp.notion.com/token":
            tokenRequests += 1
            if tokenRequests == 1 {
                await withCheckedContinuation { refreshContinuation = $0 }
                body = #"{"access_token":"refreshed-access","refresh_token":"refreshed-refresh","expires_in":3600}"#
            } else {
                body = #"{"access_token":"authorized-access","refresh_token":"authorized-refresh","expires_in":3600}"#
            }
        default:
            throw URLError(.badURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

private final class RedirectProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.operator.invalid"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ handler: @escaping (Error) -> Void) async { do { _ = try await expression(); XCTFail("Expected error") } catch { handler(error) } }
