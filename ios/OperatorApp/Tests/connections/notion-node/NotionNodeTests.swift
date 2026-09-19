import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor final class NotionNodeTests: XCTestCase {
    func testSetupMissingRedirectUsesLocalCallbackBeforeDiscovery() async {
        let transport = CountingTransport(); let store = NodeMemoryStore(loadDelay: .milliseconds(20)); let oauth = FakeOAuthPresenter()
        let client = NotionMCPClient(store: store, transport: transport)
        let setup = NativeNotionSetupCoordinator(client: client, presenter: oauth)
        XCTAssertEqual(setup.state, .idle)
        setup.connect()
        defer { setup.cancel() }
        await fulfillment(of: [transport.requested], timeout: 3)
        let count = await transport.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(oauth.calls, 0)
    }

    func testSetupRestoresUsableSavedCredentialsWithoutOpeningBrowser() async {
        let transport = CountingTransport(); let store = NodeMemoryStore(); let oauth = FakeOAuthPresenter()
        await store.set(#"{"clientID":"client","accessToken":"stored","refreshToken":"refresh"}"#)
        let setup = NativeNotionSetupCoordinator(client: NotionMCPClient(store: store, transport: transport), presenter: oauth)

        await setup.checkConnection()

        XCTAssertEqual(setup.state, .connected)
        XCTAssertEqual(oauth.calls, 0)
        let requestCount = await transport.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testSetupMissingOrCorruptCredentialsStaysIdleWithoutOpeningBrowser() async {
        for storedValue in [nil, "not-json"] {
            let transport = CountingTransport(); let store = NodeMemoryStore(); let oauth = FakeOAuthPresenter()
            if let storedValue { await store.set(storedValue) }
            let setup = NativeNotionSetupCoordinator(client: NotionMCPClient(store: store, transport: transport), presenter: oauth)

            await setup.checkConnection()

            XCTAssertEqual(setup.state, .idle)
            XCTAssertEqual(oauth.calls, 0)
            let requestCount = await transport.count()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testSetupRefreshFailureBecomesFailedWithoutOpeningBrowserOrErasingCredentials() async {
        let transport = CountingTransport(); let store = NodeMemoryStore(); let oauth = FakeOAuthPresenter()
        await store.set(#"{"clientID":"client","accessToken":"expired","refreshToken":"refresh","expiresAt":0}"#)
        let before = await store.data()
        let setup = NativeNotionSetupCoordinator(client: NotionMCPClient(store: store, transport: transport), presenter: oauth)

        await setup.checkConnection()

        XCTAssertEqual(setup.state, .failed)
        XCTAssertEqual(oauth.calls, 0)
        let requestCount = await transport.count()
        let after = await store.data()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(after, before)
    }

    func testCancelledConnectionCheckCannotReplaceCancelledState() async {
        let transport = SuspendingTransport(); let store = NodeMemoryStore(); let oauth = FakeOAuthPresenter()
        await store.set(#"{"clientID":"client","accessToken":"expired","refreshToken":"refresh","expiresAt":0}"#)
        let setup = NativeNotionSetupCoordinator(client: NotionMCPClient(store: store, transport: transport), presenter: oauth)
        let check = Task { await setup.checkConnection() }
        await fulfillment(of: [transport.started], timeout: 3)

        setup.cancel()
        await transport.release()
        await check.value

        XCTAssertEqual(setup.state, .cancelled)
        XCTAssertEqual(oauth.calls, 0)
    }
    func testRouterForwardsOnlyNotionCommandsToNotionHandler() async {
        let other = RecordingHandler(); let notion = RecordingHandler()
        let router = ForegroundNodeCommandRouter(location: other, calendar: other, messages: other, maps: other, handoff: other, whatsapp: other, whatsappCompose: other, accounts: other, accountWrite: other, notion: notion)
        _ = await router.handleNodeCommand("notion.tools", paramsJSON: "{}", timeoutMilliseconds: 9_000)
        _ = await router.handleNodeCommand("notion.call", paramsJSON: #"{"name":"x","arguments":{}}"#, timeoutMilliseconds: 8_000)
        XCTAssertEqual(notion.commands, ["notion.tools", "notion.call"]); XCTAssertTrue(other.commands.isEmpty)
    }
    func testInactiveAndInvalidNeverReachClient() async {
        let api = FakeNotionAPI(); let presenter = FakeNotionPresenter(); let service = ForegroundNotionService(client: api, presenter: presenter, isAppActive: { false })
        let inactive = await service.handleNodeCommand("notion.tools", paramsJSON: "{}", timeoutMilliseconds: nil)
        let calls0 = await api.calls(); XCTAssertEqual(inactive, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to use Notion")); XCTAssertEqual(calls0, [])
        let invalid = ForegroundNotionService(client: api, presenter: presenter, isAppActive: { true })
        _ = await invalid.handleNodeCommand("notion.call", paramsJSON: #"{"name":"x","arguments":{},"confirm":true}"#, timeoutMilliseconds: nil)
        let calls1 = await api.calls(); XCTAssertEqual(calls1, [])
    }
    func testToolsListsWithoutConfirmationAndCallRequiresExactImmutableConfirmation() async throws {
        let api = FakeNotionAPI(); let presenter = FakeNotionPresenter(); let service = ForegroundNotionService(client: api, presenter: presenter, isAppActive: { true })
        let tools = await service.handleNodeCommand("notion.tools", paramsJSON: "{}", timeoutMilliseconds: 1000); guard case .success = tools else { return XCTFail("tools") }
        presenter.decision = .confirmed(.init(name: "changed", arguments: [:]))
        let mismatch = await service.handleNodeCommand("notion.call", paramsJSON: #"{"name":"search","arguments":{"query":"x"}}"#, timeoutMilliseconds: 1000)
        let count0 = await api.callCount(); XCTAssertEqual(mismatch, .failure(code: "CONFIRMATION_MISMATCH", message: "Notion tool was not called")); XCTAssertEqual(count0, 0)
        presenter.decision = .confirmed(.init(name: "search", arguments: ["query": .string("x")]))
        _ = await service.handleNodeCommand("notion.call", paramsJSON: #"{"name":"search","arguments":{"query":"x"}}"#, timeoutMilliseconds: 1000)
        let count1 = await api.callCount(); XCTAssertEqual(count1, 1)
    }
    func testDeniedUnknownToolAndTimeoutMakeZeroCalls() async {
        let api = FakeNotionAPI(); let presenter = FakeNotionPresenter(); let service = ForegroundNotionService(client: api, presenter: presenter, isAppActive: { true })
        _ = await service.handleNodeCommand("notion.tools", paramsJSON: "{}", timeoutMilliseconds: nil)
        _ = await service.handleNodeCommand("notion.call", paramsJSON: #"{"name":"missing","arguments":{}}"#, timeoutMilliseconds: nil)
        presenter.decision = .denied; _ = await service.handleNodeCommand("notion.call", paramsJSON: #"{"name":"search","arguments":{}}"#, timeoutMilliseconds: nil)
        presenter.hang = true; _ = await service.handleNodeCommand("notion.call", paramsJSON: #"{"name":"search","arguments":{}}"#, timeoutMilliseconds: 1)
        let count = await api.callCount(); XCTAssertEqual(count, 0)
    }
}

private actor FakeNotionAPI: NotionNodeClient { var log:[String]=[]; func listTools() async throws -> [NotionTool] { log.append("list"); return [.init(name:"search",description:nil)] }; func callTool(name:String,arguments:[String:NotionJSONValue]) async throws -> NotionJSONValue { log.append("call"); return .object(["ok":.bool(true)]) }; func calls()->[String]{log}; func callCount()->Int{log.filter{$0=="call"}.count} }
@MainActor private final class FakeNotionPresenter: NotionToolConfirmationPresenting { var decision:NotionToolDecision = .denied; var hang=false; func confirm(_ request:NotionToolConfirmationRequest) async -> NotionToolDecision { if hang { try? await Task.sleep(for:.seconds(60)) }; return decision }; func cancel(){} }
@MainActor private final class FakeOAuthPresenter: OAuthSessionPresenting { var calls=0; func authenticate(url:URL,callbackScheme:String?) async throws->URL{calls += 1;throw CancellationError()};func cancel(){} }
private actor NodeMemoryStore: CredentialDataStore {
    var value: Data?
    private let loadDelay: Duration
    init(loadDelay: Duration = .zero) { self.loadDelay = loadDelay }
    func load() async throws -> Data? {
        if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
        return value
    }
    func save(_ data: Data) async throws { value = data }
    func set(_ value: String) { self.value = Data(value.utf8) }
    func data() -> Data? { value }
}
private actor CountingTransport: PhoneHTTPTransport {
    nonisolated let requested = XCTestExpectation(description: "Notion discovery requested")
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        requested.fulfill()
        throw URLError(.notConnectedToInternet)
    }
    func count() -> Int { requests.count }
}
private actor SuspendingTransport: PhoneHTTPTransport {
    nonisolated let started = XCTestExpectation(description: "Notion refresh suspended")
    private var continuation: CheckedContinuation<Void, Never>?
    func release() { continuation?.resume(); continuation = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
        throw URLError(.notConnectedToInternet)
    }
}
@MainActor private final class RecordingHandler: GatewayNodeCommandHandler { var commands:[String]=[];func handleNodeCommand(_ command:String,paramsJSON:String?,timeoutMilliseconds:Int?)async->GatewayNodeCommandResult{commands.append(command);return .success(payloadJSON:"{}")}}
