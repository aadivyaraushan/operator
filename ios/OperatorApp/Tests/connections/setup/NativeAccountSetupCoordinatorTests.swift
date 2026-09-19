import AuthenticationServices
import XCTest
@testable import OperatorApp

@MainActor final class NativeAccountSetupCoordinatorTests: XCTestCase {
#if os(iOS)
    func testProductionBundleRegistersGooglePublicClientAndCallbackScheme() {
        let clientID = "914186874774-h53ibiefs116cgg1hnrllfhn7f9cscc9.apps.googleusercontent.com"
        let callbackScheme = "com.googleusercontent.apps.914186874774-h53ibiefs116cgg1hnrllfhn7f9cscc9"
        let registration = NativeAccountSetupCoordinator.registrations(bundle: .main)[.google]

        XCTAssertEqual(registration, .init(clientID: clientID, redirectURI: "\(callbackScheme):/oauth2redirect"))

        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = urlTypes?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
        XCTAssertTrue(schemes.contains(callbackScheme))
    }

    func testProductionBundleRegistersSpotifyPublicClientAndExactLoopbackCallback() {
        XCTAssertEqual(
            NativeAccountSetupCoordinator.registrations(bundle: .main)[.spotify],
            .init(clientID: "2c348c954be24bf68d3680f206625ccd", redirectURI: "http://127.0.0.1:43827/spotify/callback"))
    }

    func testProductionBundleRegistersSlackPublicClientAndCallbackScheme() {
        let clientID = "11647883346533.12020890598643"
        let callbackScheme = "app.operator.ios"

        XCTAssertEqual(
            NativeAccountSetupCoordinator.registrations(bundle: .main)[.slack],
            .init(clientID: clientID, redirectURI: "\(callbackScheme)://oauth/slack"))

        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = urlTypes?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
        XCTAssertTrue(schemes.contains(callbackScheme))
    }

    func testProductionBundleRegistersMicrosoftOutlookPublicClientAndCallbackScheme() {
        let clientID = "ed4e4e74-ad37-4ddf-a4ca-59d3731be5e6"
        let callbackScheme = "msauth.app.operator.ios"

        XCTAssertEqual(
            NativeAccountSetupCoordinator.registrations(bundle: .main)[.microsoftOutlook],
            .init(clientID: clientID, redirectURI: "\(callbackScheme)://auth"))

        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = urlTypes?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
        XCTAssertTrue(schemes.contains(callbackScheme))
    }

    func testProductionBundleDeclaresCalendarAndLocalNetworkingRequirements() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String,
            "Operator reads your calendar only when you ask the agent for upcoming events.")
        let transportSecurity = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        XCTAssertEqual(transportSecurity?["NSAllowsLocalNetworking"] as? Bool, true)
    }
#endif

    func testReopeningRecognizesStoredConnectionWithoutStartingSignIn() async {
        let presenter = SetupPresenter()
        let model = NativeAccountSetupCoordinator(registrations: [.google: .init(clientID: "g", redirectURI: "operator://g")], presenter: presenter) { _, _ in
            .init(begin: { XCTFail("must not start sign-in"); return .request }, complete: { _ in XCTFail("must not exchange"); return .fixture }, accessToken: { "stored-token" })
        }
        await model.checkConnections()
        XCTAssertEqual(model.state(for: .google), .connected)
        XCTAssertEqual(model.state(for: .spotify), .needsSetup)
        XCTAssertEqual(presenter.calls, 0)
    }
    func testMissingRegistrationNeedsSetupWithoutPresenting() {
        let presenter = SetupPresenter(); let model = NativeAccountSetupCoordinator(registrations: [:], presenter: presenter, clients: { _, _ in XCTFail(); return .unused })
        model.connect(.google)
        XCTAssertEqual(model.state(for: .google), .needsSetup); XCTAssertEqual(presenter.calls, 0)
    }
    func testOnlyOneAuthorizationRunsAndCallbackCompletes() async {
        let presenter = SetupPresenter(); let counter = Counter()
        let model = NativeAccountSetupCoordinator(registrations: [.google: .init(clientID: "id", redirectURI: "operator://oauth")], presenter: presenter) { _, _ in
            .init(begin: { await counter.begin(); return .request }, complete: { _ in await counter.complete(); return .fixture }, accessToken: { "token" })
        }
        model.connect(.google); model.connect(.google)
        await fulfillment(of: [presenter.presented], timeout: 1); presenter.finish(URL(string: "operator://oauth?code=x&state=state")!)
        await waitUntil { model.state(for: .google) == .connected }
        let values = await counter.values(); XCTAssertEqual(values, [1, 1]); XCTAssertEqual(model.state(for: .google), .connected)
    }
    func testCancelPreventsOldCallbackFromClobberingNewRun() async {
        let presenter = SetupPresenter(); let counter = Counter()
        let model = NativeAccountSetupCoordinator(registrations: [.slack: .init(clientID: "id", redirectURI: "operator://oauth")], presenter: presenter) { _, _ in
            .init(begin: { await counter.begin(); return .request }, complete: { _ in await counter.complete(); return .fixture }, accessToken: { "secret" })
        }
        model.connect(.slack); await fulfillment(of: [presenter.presented], timeout: 1); model.cancel(); await Task.yield()
        let values = await counter.values(); XCTAssertEqual(presenter.cancels, 1); XCTAssertEqual(values, [1, 0]); XCTAssertEqual(model.state(for: .slack), .cancelled)
    }

    func testBrowserCancelledLoginNormalizesToCancellation() {
        let error = NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue)

        XCTAssertTrue(OAuthSessionCancellation.normalized(error) is CancellationError)
    }
    func testCachesOneClientPerProviderAndKeepsProviderTokensSeparate() async throws {
        let presenter = SetupPresenter(); let factories = Counter()
        let model = NativeAccountSetupCoordinator(registrations: [.google: .init(clientID: "g", redirectURI: "operator://g"), .spotify: .init(clientID: "s", redirectURI: "operator://s")], presenter: presenter) { provider, _ in
            Task { await factories.begin() }; return .init(begin: { .request }, complete: { _ in .fixture }, accessToken: { provider.rawValue })
        }
        let google1 = try await model.accessToken(.google); let google2 = try await model.accessToken(.google); let spotify = try await model.accessToken(.spotify)
        XCTAssertEqual(google1, "google"); XCTAssertEqual(google2, "google"); XCTAssertEqual(spotify, "spotify")
        await Task.yield(); let values = await factories.values(); XCTAssertEqual(values[0], 2)
    }
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async { for _ in 0..<100 { if condition() { return }; await Task.yield() }; XCTFail("condition not reached") }
}

private actor Counter { var begins = 0; var completes = 0; func begin() { begins += 1 }; func complete() { completes += 1 }; func values() -> [Int] { [begins, completes] } }
@MainActor private final class SetupPresenter: OAuthSessionPresenting {
    let presented = XCTestExpectation(description: "presented"); var calls = 0; var cancels = 0; var continuation: CheckedContinuation<URL, Error>?
    func authenticate(url: URL, callbackScheme: String?) async throws -> URL { calls += 1; presented.fulfill(); return try await withCheckedThrowingContinuation { continuation = $0 } }
    func cancel() { cancels += 1; continuation?.resume(throwing: CancellationError()); continuation = nil }
    func finish(_ url: URL) { continuation?.resume(returning: url); continuation = nil }
}
private extension OAuthClientOperations { static var unused: Self { .init(begin: { throw CancellationError() }, complete: { _ in throw CancellationError() }, accessToken: { throw CancellationError() }) } }
private extension OAuthAuthorizationRequest { static var request: Self { .init(url: URL(string: "https://example.test/auth")!, state: "state", codeVerifier: "verifier") } }
private extension OAuthTokens { static var fixture: Self { .init(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, grantedScopes: []) } }
