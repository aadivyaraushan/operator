import Foundation
import Network
import XCTest
@testable import OperatorApp

@MainActor final class SpotifyLoopbackSetupTests: XCTestCase {
    func testSpotifyUsesExactLocalCallbackAndCompletesExistingClient() async throws {
        let port = try await availableLoopbackPort()
        let redirect = URL(string: "http://127.0.0.1:\(port)/spotify/callback")!
        let presenter = SpotifyPresenter(callback: callback(redirect, code: "private-code", state: "expected-state"))
        let calls = OAuthCallCounter()
        let model = NativeAccountSetupCoordinator(
            registrations: [.spotify: .init(clientID: "public-client-id", redirectURI: redirect.absoluteString)],
            presenter: presenter
        ) { provider, registration in
            XCTAssertEqual(provider, .spotify)
            XCTAssertEqual(registration.redirectURI, redirect.absoluteString)
            return .init(
                begin: {
                    await calls.recordBegin()
                    return .init(
                        url: URL(string: "https://accounts.spotify.com/authorize?state=expected-state")!,
                        state: "expected-state",
                        codeVerifier: "verifier")
                },
                complete: { url in
                    await calls.recordComplete(url)
                    return .fixture
                },
                accessToken: { throw PhoneOAuthError.notConnected })
        }

        model.connect(.spotify)

        await waitUntil { model.state(for: .spotify) == .connected }
        let values = await calls.values()
        XCTAssertEqual(values.begins, 1)
        XCTAssertEqual(values.completes, [callback(redirect, code: "private-code", state: "expected-state")])
        XCTAssertEqual(presenter.callbackSchemes, [nil])
        XCTAssertGreaterThanOrEqual(presenter.cancels, 1)
    }

    func testSpotifyCancelClosesListenerAndDismissesPresenter() async throws {
        let port = try await availableLoopbackPort()
        let redirect = URL(string: "http://127.0.0.1:\(port)/spotify/callback")!
        let presenter = SpotifyPresenter(callback: nil)
        let calls = OAuthCallCounter()
        let model = NativeAccountSetupCoordinator(
            registrations: [.spotify: .init(clientID: "public-client-id", redirectURI: redirect.absoluteString)],
            presenter: presenter
        ) { _, _ in
            .init(
                begin: {
                    await calls.recordBegin()
                    return .init(
                        url: URL(string: "https://accounts.spotify.com/authorize?state=expected-state")!,
                        state: "expected-state",
                        codeVerifier: "verifier")
                },
                complete: { url in await calls.recordComplete(url); return .fixture },
                accessToken: { throw PhoneOAuthError.notConnected })
        }

        model.connect(.spotify)
        await fulfillment(of: [presenter.presented], timeout: 1)
        model.cancel()

        await waitUntil { model.state(for: .spotify) == .cancelled }
        let values = await calls.values()
        XCTAssertEqual(values.begins, 1)
        XCTAssertTrue(values.completes.isEmpty)
        XCTAssertGreaterThanOrEqual(presenter.cancels, 1)
        await assertListenerClosed(redirect)
    }

    func testSpotifyRejectsNonExactLoopbackRegistrationBeforeStartingAuth() async {
        let invalidRedirects = [
            "operator://spotify/callback",
            "http://localhost:43827/spotify/callback",
            "https://127.0.0.1:43827/spotify/callback",
            "http://127.0.0.1/spotify/callback",
            "http://127.0.0.1:43827/wrong",
            "http://127.0.0.1:43827/spotify/callback?extra=value",
        ]
        for redirect in invalidRedirects {
            let presenter = SpotifyPresenter(callback: nil)
            let calls = OAuthCallCounter()
            let model = NativeAccountSetupCoordinator(
                registrations: [.spotify: .init(clientID: "public-client-id", redirectURI: redirect)],
                presenter: presenter
            ) { _, _ in
                Task { await calls.recordFactory() }
                return .unused
            }

            model.connect(.spotify)
            await Task.yield()

            XCTAssertEqual(model.state(for: .spotify), .needsSetup, redirect)
            XCTAssertEqual(presenter.calls, 0, redirect)
            let factoryCalls = await calls.factoryCalls()
            XCTAssertEqual(factoryCalls, 0, redirect)
        }
    }

    func testSpotifyListenerRejectsWrongStatePathAndHostPort() async throws {
        try await assertRejected(pathAndQuery: "/spotify/callback?code=c&state=wrong", hostPortDelta: 0)
        try await assertRejected(pathAndQuery: "/wrong?code=c&state=expected-state", hostPortDelta: 0)
        try await assertRejected(pathAndQuery: "/spotify/callback?code=c&state=expected-state", hostPortDelta: 1)
    }

    func testSpotifyListenerTimeoutClosesPort() async throws {
        let server = LocalOAuthCallbackServer(
            path: "/spotify/callback",
            logTag: "spotify-loopback",
            timeoutSeconds: 0.02)
        let redirect = try await server.start(port: nil)

        await XCTAssertThrowsErrorAsync(try await server.receive(expectedState: "expected-state")) {
            XCTAssertEqual($0 as? LocalOAuthCallbackError, .timedOut)
        }
        await assertListenerClosed(redirect)
    }

    func testSpotifySuccessResponseDoesNotExposeCodeStateOrRegistration() async throws {
        let server = LocalOAuthCallbackServer(path: "/spotify/callback", logTag: "spotify-loopback", timeoutSeconds: 2)
        let redirect = try await server.start(port: nil)
        let callbackURL = callback(redirect, code: "private-code", state: "private-state")
        let receive = Task { try await server.receive(expectedState: "private-state") }

        let (body, response) = try await URLSession.shared.data(from: callbackURL)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("private-code"))
        XCTAssertFalse(text.contains("private-state"))
        XCTAssertFalse(text.contains("public-client-id"))
        let received = try await receive.value
        XCTAssertEqual(received, callbackURL)
    }

    private func assertRejected(pathAndQuery: String, hostPortDelta: Int) async throws {
        let server = LocalOAuthCallbackServer(path: "/spotify/callback", logTag: "spotify-loopback", timeoutSeconds: 2)
        let redirect = try await server.start(port: nil)
        let receive = Task { try await server.receive(expectedState: "expected-state") }
        let actualPort = try XCTUnwrap(redirect.port)
        let advertisedPort = actualPort + hostPortDelta
        let response = try await rawRequest(
            "GET \(pathAndQuery) HTTP/1.1\r\nHost: 127.0.0.1:\(advertisedPort)\r\n\r\n",
            port: actualPort)
        XCTAssertTrue(response.contains("400 Bad Request"))
        await XCTAssertThrowsErrorAsync(try await receive.value) {
            XCTAssertEqual($0 as? LocalOAuthCallbackError, .invalidRequest)
        }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        // A real loopback HTTP round trip. A passing run satisfies the
        // condition almost immediately; the ceiling only bounds a genuine
        // hang. 1s was too tight on a Simulator running the whole suite at
        // once (the round trip lost to scheduling and flaked), so allow 3s.
        for _ in 0..<600 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not reached")
    }
}

@MainActor private final class SpotifyPresenter: OAuthSessionPresenting {
    let presented = XCTestExpectation(description: "Spotify browser presented")
    private let callback: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    var calls = 0
    var cancels = 0
    var callbackSchemes: [String?] = []

    init(callback: URL?) { self.callback = callback }

    func authenticate(url: URL, callbackScheme: String?) async throws -> URL {
        calls += 1
        callbackSchemes.append(callbackScheme)
        presented.fulfill()
        if let callback {
            Task.detached {
                _ = try? await URLSession.shared.data(from: callback)
            }
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() {
        cancels += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor OAuthCallCounter {
    private var factoryCount = 0
    private var beginCount = 0
    private var completedURLs: [URL] = []
    func recordFactory() { factoryCount += 1 }
    func recordBegin() { beginCount += 1 }
    func recordComplete(_ url: URL) { completedURLs.append(url) }
    func factoryCalls() -> Int { factoryCount }
    func values() -> (begins: Int, completes: [URL]) { (beginCount, completedURLs) }
}

private func callback(_ redirect: URL, code: String, state: String) -> URL {
    var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
    components.queryItems = [.init(name: "code", value: code), .init(name: "state", value: state)]
    return components.url!
}

private func availableLoopbackPort() async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { $0.cancel() }
    let queue = DispatchQueue(label: "spotify-loopback-port-reservation")
    return try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue
                listener.cancel()
                if let port { continuation.resume(returning: port) }
                else { continuation.resume(throwing: TestError.noPort) }
            case .failed(let error):
                listener.cancel()
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }
}

private func rawRequest(_ request: String, port: Int) async throws -> String {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: UInt16(port))!,
        using: .tcp)
    connection.start(queue: DispatchQueue(label: "spotify-loopback-raw-request"))
    defer { connection.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        })
    }
    let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: data ?? Data()) }
        }
    }
    return String(decoding: data, as: UTF8.self)
}

@MainActor private func assertListenerClosed(_ redirect: URL) async {
    do {
        _ = try await URLSession.shared.data(from: redirect)
        XCTFail("listener remained open")
    } catch {
        XCTAssertTrue(true)
    }
}

@MainActor private func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    _ check: (Error) -> Void = { _ in }
) async {
    do { _ = try await expression(); XCTFail("Expected error") }
    catch { check(error) }
}

private enum TestError: Error { case noPort }

private extension OAuthClientOperations {
    static var unused: Self {
        .init(
            begin: { throw CancellationError() },
            complete: { _ in throw CancellationError() },
            accessToken: { throw CancellationError() })
    }
}

private extension OAuthTokens {
    static var fixture: Self {
        .init(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: .distantFuture,
            grantedScopes: OAuthProvider.spotify.scopes)
    }
}
