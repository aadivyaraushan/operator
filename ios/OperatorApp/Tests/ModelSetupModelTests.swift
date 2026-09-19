import XCTest
@testable import OperatorApp

@MainActor
final class ModelSetupModelTests: XCTestCase {
    func testOlderFailedCheckCannotHideNewerSignInResult() async {
        let gateway = OverlappingCheckGateway()
        let model = ModelSetupModel(gateway: gateway)
        let olderCheck = Task { await model.check() }
        await gateway.waitForFirstRequest()

        await model.check()
        XCTAssertEqual(model.state, .needsSignIn)
        await gateway.completeFirst(.failure(NSError(domain: "test.configuration", code: 1)))
        await olderCheck.value

        XCTAssertEqual(model.state, .needsSignIn, "An early startup failure must not hide the newer sign-in banner")
    }

    func testOlderSuccessfulCheckCannotReplaceNewerSignInResult() async {
        let gateway = OverlappingCheckGateway()
        let model = ModelSetupModel(gateway: gateway)
        let olderCheck = Task { await model.check() }
        await gateway.waitForFirstRequest()

        await model.check()
        XCTAssertEqual(model.state, .needsSignIn)
        await gateway.completeFirst(.success(.init(hasConfiguredModel: true)))
        await olderCheck.value

        XCTAssertEqual(model.state, .needsSignIn, "Only the latest account check may update setup")
    }
    func testFrameworkClosingCompletedSheetDoesNotReplaceReadyState() async {
        let gateway = SetupGatewayStub(configurations: [], starts: [Self.completed])
        let model = ModelSetupModel(gateway: gateway)

        await model.beginChatGPTSignIn()
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.isPresented)

        model.dismiss()

        XCTAssertEqual(model.state, .ready)
        let cancelled = await gateway.cancelledSessions()
        XCTAssertEqual(cancelled, [])
    }

    func testDismissCancelsVisibleAuthorization() async {
        let gateway = SetupGatewayStub(
            configurations: [],
            starts: [.init(sessionID: "active-session", done: false, step: Self.clientStep,
                           status: "running", error: nil, modelActivation: nil)])
        let model = ModelSetupModel(gateway: gateway)

        await model.beginChatGPTSignIn()
        XCTAssertTrue(model.isPresented)

        model.dismiss()
        await Task.yield()

        XCTAssertEqual(model.state, .needsSignIn)
        XCTAssertFalse(model.isPresented)
        let cancelled = await gateway.cancelledSessions()
        XCTAssertEqual(cancelled, ["active-session"])
    }

    func testForegroundCheckPreservesAwaitingClientAuthorization() async {
        let step = Self.clientStep
        let gateway = SetupGatewayStub(
            configurations: [.init(hasConfiguredModel: false)],
            starts: [.init(sessionID: "active-session", done: false, step: step,
                           status: "running", error: nil, modelActivation: nil)])
        let model = ModelSetupModel(gateway: gateway)

        await model.beginChatGPTSignIn()
        await model.check()

        XCTAssertEqual(model.state, .awaitingAuthorization(step))
        let checks = await gateway.configurationRequests()
        let starts = await gateway.startedSessions()
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(starts.count, 1)
    }

    func testLateForegroundCheckDoesNotOverwriteNewAuthorizationStep() async {
        let step = Self.clientStep
        let gateway = SetupGatewayStub(
            configurations: [.init(hasConfiguredModel: false)],
            starts: [.init(sessionID: "active-session", done: false, step: step,
                           status: "running", error: nil, modelActivation: nil)],
            holdConfigurations: true)
        let model = ModelSetupModel(gateway: gateway)

        let check = Task { await model.check() }
        for _ in 0 ..< 100 where await gateway.configurationRequests() == 0 {
            await Task.yield()
        }
        await model.beginChatGPTSignIn()
        await gateway.releaseConfiguration()
        await check.value

        XCTAssertEqual(model.state, .awaitingAuthorization(step))
    }

    func testLateFailedForegroundCheckDoesNotOverwriteNewAuthorizationStep() async {
        let step = Self.clientStep
        let gateway = SetupGatewayStub(
            configurations: [],
            starts: [.init(sessionID: "active-session", done: false, step: step,
                           status: "running", error: nil, modelActivation: nil)],
            holdConfigurations: true,
            configurationFailures: 1)
        let model = ModelSetupModel(gateway: gateway)

        let check = Task { await model.check() }
        for _ in 0 ..< 100 where await gateway.configurationRequests() == 0 {
            await Task.yield()
        }
        await model.beginChatGPTSignIn()
        await gateway.releaseConfiguration()
        await check.value

        XCTAssertEqual(model.state, .awaitingAuthorization(step))
    }

    func testLateUnconfiguredCheckDoesNotOverwriteCompletedSignIn() async {
        let gateway = SetupGatewayStub(
            configurations: [.init(hasConfiguredModel: false)],
            starts: [Self.completed],
            holdConfigurations: true)
        let model = ModelSetupModel(gateway: gateway)

        let check = Task { await model.check() }
        for _ in 0 ..< 100 where await gateway.configurationRequests() == 0 {
            await Task.yield()
        }
        await model.beginChatGPTSignIn()
        XCTAssertEqual(model.state, .ready)
        await gateway.releaseConfiguration()
        await check.value

        XCTAssertEqual(model.state, .ready)
    }

    func testLateFailedCheckDoesNotOverwriteCompletedSignIn() async {
        let gateway = SetupGatewayStub(
            configurations: [],
            starts: [Self.completed],
            holdConfigurations: true,
            configurationFailures: 1)
        let model = ModelSetupModel(gateway: gateway)

        let check = Task { await model.check() }
        for _ in 0 ..< 100 where await gateway.configurationRequests() == 0 {
            await Task.yield()
        }
        await model.beginChatGPTSignIn()
        XCTAssertEqual(model.state, .ready)
        await gateway.releaseConfiguration()
        await check.value

        XCTAssertEqual(model.state, .ready)
    }

    func testForegroundCheckPreservesPendingActivation() async {
        let gateway = SetupGatewayStub(
            configurations: [.init(hasConfiguredModel: false)],
            starts: [Self.completed],
            verificationFails: true)
        let model = ModelSetupModel(gateway: gateway)

        await model.beginChatGPTSignIn()
        await model.check()

        guard case .failed = model.state else { return XCTFail("Pending activation must remain recoverable") }
        let checks = await gateway.configurationRequests()
        XCTAssertEqual(checks, 0)
    }

    func testRepeatedBeginPreservesActiveAuthorizationWithoutSecondStart() async {
        let step = Self.clientStep
        let gateway = SetupGatewayStub(
            configurations: [],
            starts: [.init(sessionID: "active-session", done: false, step: step,
                           status: "running", error: nil, modelActivation: nil)])
        let model = ModelSetupModel(gateway: gateway)

        await model.beginChatGPTSignIn()
        await model.beginChatGPTSignIn()

        XCTAssertEqual(model.state, .awaitingAuthorization(step))
        let starts = await gateway.startedSessions()
        XCTAssertEqual(starts.count, 1)
    }

    private static var clientStep: ModelSetupWizardStep {
        .init(id: "authorization-step", type: "note", title: nil, message: nil,
              executor: "client", externalURL: nil, deviceCode: nil)
    }

    func testRetryAfterStartFailureBeginsFreshSignIn() async {
        let gateway = SetupGatewayStub(configurations: [], starts: [Self.completed], startFailures: 1)
        let model = ModelSetupModel(gateway: gateway)
        await model.beginChatGPTSignIn()
        guard case .failed = model.state else { return XCTFail("Expected initial start failure") }

        await model.retry()

        XCTAssertEqual(model.state, .ready)
        let sessions = await gateway.startedSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions).count, 2, "Retry should use a fresh sign-in session")
    }

    func testRetryAfterNextFailureRetriesSameClientStepWithoutNewSignIn() async {
        let step = ModelSetupWizardStep(
            id: "authorization-step", type: "note", title: nil, message: nil,
            executor: "client", externalURL: nil, deviceCode: nil)
        let gateway = SetupGatewayStub(
            configurations: [],
            starts: [.init(sessionID: "existing-session", done: false, step: step,
                           status: "running", error: nil, modelActivation: nil)],
            advances: [Self.completed], nextFailures: 1)
        let model = ModelSetupModel(gateway: gateway)
        await model.beginChatGPTSignIn()
        await model.continueSignIn()
        guard case .failed = model.state else { return XCTFail("Expected initial next failure") }

        await model.retry()

        XCTAssertEqual(model.state, .ready)
        let answers = await gateway.answers()
        let advancedSessions = await gateway.advancedSessions()
        let startedSessions = await gateway.startedSessions()
        XCTAssertEqual(answers, ["authorization-step", "authorization-step"])
        XCTAssertEqual(advancedSessions, ["existing-session", "existing-session"])
        XCTAssertEqual(startedSessions.count, 1, "Retry must not start another authorization")
    }

    func testActivationIsVerifiedBeforeReadyAndCompletionCallback() async {
        let gateway = SetupGatewayStub(configurations: [], starts: [Self.completed])
        var callbackSawVerification = false
        let model = ModelSetupModel(gateway: gateway) {
            callbackSawVerification = await gateway.wasVerified()
        }
        await model.beginChatGPTSignIn()
        XCTAssertTrue(callbackSawVerification)
        XCTAssertEqual(model.state, .ready)
    }

    func testVerificationFailureNeverBecomesReadyOrCallsCompletion() async {
        let gateway = SetupGatewayStub(configurations: [], starts: [Self.completed], verificationFails: true)
        var callbackCalled = false
        let model = ModelSetupModel(gateway: gateway) { callbackCalled = true }
        await model.beginChatGPTSignIn()
        XCTAssertFalse(callbackCalled)
        guard case .failed = model.state else { return XCTFail("Unverified setup must fail") }
        XCTAssertTrue(model.isPresented)
    }

    func testRetryAfterVerificationFailureReusesActivationWithoutNewSignIn() async {
        let gateway = SetupGatewayStub(configurations: [], starts: [Self.completed], verificationFails: true)
        var callbackCalled = false
        let model = ModelSetupModel(gateway: gateway) { callbackCalled = true }
        await model.beginChatGPTSignIn()
        await gateway.allowVerification()
        await model.retry()
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(callbackCalled)
        XCTAssertFalse(model.isPresented)
    }

    private static var completed: ModelSetupWizardResult {
        .init(sessionID: "setup", done: true, step: nil, status: "done", error: nil,
              modelActivation: .init(modelRef: "test/model", gatewayRestartRequired: true))
    }

    func testAlreadyConfiguredGatewayBecomesReadyWithoutShowingSetup() async {
        let gateway = SetupGatewayStub(
            configurations: [.init(hasConfiguredModel: true)])
        let model = ModelSetupModel(gateway: gateway)

        await model.check()

        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.isPresented)
    }

    func testAccountCheckRetryRechecksWithoutStartingSignIn() async {
        let gateway = SetupGatewayStub(configurations: [
            .init(hasConfiguredModel: false),
            .init(hasConfiguredModel: true)
        ])
        let model = ModelSetupModel(gateway: gateway)

        await model.check()
        await model.retryAccountCheck()

        XCTAssertEqual(model.state, .ready)
        let sessions = await gateway.startedSessions()
        XCTAssertTrue(sessions.isEmpty, "Account check retry must not start sign-in")
    }

    func testDeviceCodeFlowShowsExactCodeThenCompletes() async throws {
        let signInURL = try XCTUnwrap(URL(string: "https://auth.openai.com/device"))
        let deviceStep = ModelSetupWizardStep(
            id: "device-code-step",
            type: "note",
            title: "Authorize ChatGPT",
            message: "Open the sign-in page and enter this code.",
            executor: "client",
            externalURL: signInURL,
            deviceCode: .init(code: "ABCD-1234", expiresInMinutes: 15, message: nil))
        let gateway = SetupGatewayStub(
            configurations: [.init(hasConfiguredModel: false)],
            starts: [.init(
                sessionID: "setup-1",
                done: false,
                step: nil,
                status: "running",
                error: nil,
                modelActivation: nil)],
            advances: [
                .init(
                    sessionID: nil,
                    done: false,
                    step: deviceStep,
                    status: "running",
                    error: nil,
                    modelActivation: nil),
                .init(
                    sessionID: nil,
                    done: true,
                    step: nil,
                    status: "done",
                    error: nil,
                    modelActivation: .init(
                        modelRef: "openai/gpt-5.5",
                        gatewayRestartRequired: nil)),
            ])
        let model = ModelSetupModel(gateway: gateway)

        await model.check()
        XCTAssertEqual(model.state, .needsSignIn)

        await model.beginChatGPTSignIn()
        XCTAssertEqual(model.state, .awaitingAuthorization(deviceStep))
        XCTAssertTrue(model.isPresented)

        await model.continueSignIn()
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.isPresented)
        let answers = await gateway.answers()
        XCTAssertEqual(answers, [nil, "device-code-step"])
    }
}

private actor OverlappingCheckGateway: ModelSetupGateway {
    private var requests = 0
    private var first: CheckedContinuation<ModelSetupConfiguration, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func configuration() async throws -> ModelSetupConfiguration {
        requests += 1
        guard requests == 1 else { return .init(hasConfiguredModel: false) }
        return try await withCheckedThrowingContinuation { continuation in
            first = continuation
            started?.resume()
            started = nil
        }
    }
    func waitForFirstRequest() async {
        guard first == nil else { return }
        await withCheckedContinuation { started = $0 }
    }
    func completeFirst(_ result: Result<ModelSetupConfiguration, Error>) {
        first?.resume(with: result)
        first = nil
    }
    func startDeviceCode(sessionID: String) async throws -> ModelSetupWizardResult { fatalError("Not used") }
    func next(sessionID: String, answeringStepID: String?) async throws -> ModelSetupWizardResult { fatalError("Not used") }
    func verifyActivation(_ activation: ModelSetupActivation) async throws { fatalError("Not used") }
    func cancel(sessionID: String) async {}
    func disconnect() async {}
}

private actor SetupGatewayStub: ModelSetupGateway {
    private var configurations: [ModelSetupConfiguration]
    private var starts: [ModelSetupWizardResult]
    private var advances: [ModelSetupWizardResult]
    private var recordedAnswers: [String?] = []
    private var verified = false
    private var verificationFails: Bool
    private var startFailures: Int
    private var nextFailures: Int
    private var recordedStartedSessions: [String] = []
    private var recordedAdvancedSessions: [String] = []
    private var recordedCancelledSessions: [String] = []
    private let holdConfigurations: Bool
    private var configurationRequestCount = 0
    private var configurationRelease: CheckedContinuation<Void, Never>?
    private var configurationFailures: Int

    init(
        configurations: [ModelSetupConfiguration],
        starts: [ModelSetupWizardResult] = [],
        advances: [ModelSetupWizardResult] = [],
        verificationFails: Bool = false,
        startFailures: Int = 0,
        nextFailures: Int = 0,
        holdConfigurations: Bool = false,
        configurationFailures: Int = 0)
    {
        self.configurations = configurations
        self.starts = starts
        self.advances = advances
        self.verificationFails = verificationFails
        self.startFailures = startFailures
        self.nextFailures = nextFailures
        self.holdConfigurations = holdConfigurations
        self.configurationFailures = configurationFailures
    }

    func configuration() async throws -> ModelSetupConfiguration {
        self.configurationRequestCount += 1
        if self.holdConfigurations {
            await withCheckedContinuation { self.configurationRelease = $0 }
        }
        if self.configurationFailures > 0 {
            self.configurationFailures -= 1
            throw NSError(domain: "test.configuration", code: 1)
        }
        return self.configurations.removeFirst()
    }

    func startDeviceCode(sessionID: String) async throws -> ModelSetupWizardResult {
        self.recordedStartedSessions.append(sessionID)
        if self.startFailures > 0 {
            self.startFailures -= 1
            throw NSError(domain: "test.start", code: 1)
        }
        return self.starts.removeFirst()
    }

    func next(sessionID: String, answeringStepID: String?) async throws -> ModelSetupWizardResult {
        self.recordedAdvancedSessions.append(sessionID)
        self.recordedAnswers.append(answeringStepID)
        if self.nextFailures > 0 {
            self.nextFailures -= 1
            throw NSError(domain: "test.next", code: 1)
        }
        return self.advances.removeFirst()
    }

    func disconnect() async {}

    func verifyActivation(_ activation: ModelSetupActivation) async throws {
        if verificationFails { throw NSError(domain: "test", code: 1) }
        verified = true
    }

    func wasVerified() -> Bool { verified }
    func allowVerification() { verificationFails = false }
    func startedSessions() -> [String] { recordedStartedSessions }
    func advancedSessions() -> [String] { recordedAdvancedSessions }
    func cancelledSessions() -> [String] { recordedCancelledSessions }
    func configurationRequests() -> Int { self.configurationRequestCount }
    func releaseConfiguration() { self.configurationRelease?.resume(); self.configurationRelease = nil }

    func cancel(sessionID: String) async { self.recordedCancelledSessions.append(sessionID) }

    func answers() -> [String?] {
        self.recordedAnswers
    }
}
