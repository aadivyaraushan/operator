import Foundation
import XCTest
import OperatorCore
@testable import OperatorApp

final class LocalModelSetupGatewayTests: XCTestCase {
    func testProductionVerificationBudgetCoversReconnectAndServerProbe() async {
        let gateway = LocalModelSetupGateway(connectionFactory: {
            OpenClawGatewayConnection(
                transport: ScriptedSetupTransport(bootID: "one"), token: "test", identity: GatewayDeviceIdentity(),
                metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {})
        })

        XCTAssertEqual(LocalModelSetupGateway.serverSetupProbeTimeout, .seconds(90))
        XCTAssertEqual(LocalModelSetupGateway.gatewayReconnectTimeout, .seconds(60))
        XCTAssertEqual(LocalModelSetupGateway.productionVerificationTimeout, .seconds(150))
        let timeout = await gateway.verificationTimeout
        XCTAssertEqual(timeout, LocalModelSetupGateway.productionVerificationTimeout)
    }

    func testConfigurationClosesFirstConnectionBeforeSecondRead() async throws {
        let first = ScriptedSetupTransport(
            bootID: "one", config: #"{"valid":true,"config":{"agents":{"defaults":{"model":"openai/first"}}}}"#)
        let second = ScriptedSetupTransport(
            bootID: "two", config: #"{"valid":true,"config":{"agents":{"defaults":{"model":"openai/second"}}}}"#)
        let factory = SetupConnectionFactory([first, second])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() })

        _ = try await gateway.configuration()
        _ = try await gateway.configuration()

        let firstMethods = await first.methods
        let secondMethods = await second.methods
        let firstClosed = await first.closed
        let secondClosed = await second.closed
        XCTAssertEqual(firstMethods, ["connect", "config.get"])
        XCTAssertEqual(secondMethods, ["connect", "config.get"])
        XCTAssertTrue(firstClosed)
        XCTAssertTrue(secondClosed)
    }

    func testConfigurationUsesChatAgentOverrideAndNeverCallsSetupDetection() async throws {
        let transport = ScriptedSetupTransport(
            bootID: "one",
            config: #"{"valid":true,"config":{"agents":{"defaults":{"model":"openai/default"},"entries":{"main":{"model":{"primary":"openai/override"}}}}}}"#)
        let gateway = LocalModelSetupGateway(connectionFactory: { OpenClawGatewayConnection(
            transport: transport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {}) })

        let configuration = try await gateway.configuration()

        XCTAssertTrue(configuration.hasConfiguredModel)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["connect", "config.get"])
        XCTAssertFalse(methods.contains("openclaw.setup.detect"))
    }

    func testConfigurationUsesOnlyMainEntryOverrideWhenDefaultsHaveNoModel() async throws {
        let transport = ScriptedSetupTransport(
            bootID: "one",
            config: #"{"valid":true,"config":{"agents":{"defaults":{},"entries":{"main":{"model":"openai/main-only"}}}}}"#)
        let gateway = LocalModelSetupGateway(connectionFactory: { OpenClawGatewayConnection(
            transport: transport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {}) })

        let configuration = try await gateway.configuration()

        XCTAssertTrue(configuration.hasConfiguredModel)
    }

    func testConfigurationReadsLegacyListButEntriesStillTakePrecedence() async throws {
        let listTransport = ScriptedSetupTransport(
            bootID: "one",
            config: #"{"valid":true,"config":{"agents":{"defaults":{},"list":[{"id":"main","model":{"primary":"openai/list-main"}}]}}}"#)
        let listGateway = LocalModelSetupGateway(connectionFactory: { OpenClawGatewayConnection(
            transport: listTransport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {}) })
        let listConfiguration = try await listGateway.configuration()
        XCTAssertTrue(listConfiguration.hasConfiguredModel)

        let entriesTransport = ScriptedSetupTransport(
            bootID: "one",
            config: #"{"valid":true,"config":{"agents":{"defaults":{},"entries":{},"list":[{"id":"main","model":"openai/list-must-not-win"}]}}}"#)
        let entriesGateway = LocalModelSetupGateway(connectionFactory: { OpenClawGatewayConnection(
            transport: entriesTransport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {}) })
        let entriesConfiguration = try await entriesGateway.configuration()
        XCTAssertFalse(entriesConfiguration.hasConfiguredModel)
    }

    func testConfigurationFallsBackToDefaultAndRejectsBlankOrInvalidConfig() async throws {
        let defaultTransport = ScriptedSetupTransport(
            bootID: "one",
            config: #"{"valid":true,"config":{"agents":{"defaults":{"model":{"primary":" openai/default "}},"entries":{"main":{"model":"   "}}}}}"#)
        let defaultGateway = LocalModelSetupGateway(connectionFactory: { OpenClawGatewayConnection(
            transport: defaultTransport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {}) })
        let defaultConfiguration = try await defaultGateway.configuration()
        XCTAssertTrue(defaultConfiguration.hasConfiguredModel)

        let blankTransport = ScriptedSetupTransport(
            bootID: "one", config: #"{"valid":true,"config":{"agents":{"defaults":{"model":" "}}}}"#)
        let blankGateway = LocalModelSetupGateway(connectionFactory: { OpenClawGatewayConnection(
            transport: blankTransport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {}) })
        let blankConfiguration = try await blankGateway.configuration()
        XCTAssertFalse(blankConfiguration.hasConfiguredModel)

        let invalidTransport = ScriptedSetupTransport(bootID: "one", config: #"{"valid":false,"config":{}}"#)
        let invalidGateway = LocalModelSetupGateway(connectionFactory: { OpenClawGatewayConnection(
            transport: invalidTransport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {}) })
        do {
            _ = try await invalidGateway.configuration()
            XCTFail("Invalid config must be unavailable")
        } catch {}
    }

    func testRestartRetriesTransportFailureThenVerifiesNewBoot() async throws {
        let factory = SetupConnectionFactory([
            ScriptedSetupTransport(bootID: "old"),
            ScriptedSetupTransport(bootID: "new", failsOpen: true),
            ScriptedSetupTransport(bootID: "new"),
        ])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() }, verificationTimeout: .seconds(2))
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: true))
    }

    func testMissingNewBootIdentityFailsBeforeVerification() async throws {
        let new = ScriptedSetupTransport(bootID: nil)
        let factory = SetupConnectionFactory([ScriptedSetupTransport(bootID: "old"), new])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() })
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        do {
            try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: true))
            XCTFail("Missing replacement boot must fail")
        } catch {}
        let methods = await new.methods
        XCTAssertEqual(methods, ["connect"])
    }

    func testHungRestartHandshakeIsClosedAtDeadline() async throws {
        let new = ScriptedSetupTransport(bootID: "new", hangConnect: true)
        let factory = SetupConnectionFactory([ScriptedSetupTransport(bootID: "old"), new])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() }, verificationTimeout: .milliseconds(80))
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        let start = ContinuousClock.now
        do {
            try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: true))
            XCTFail("Hung connection must time out")
        } catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let closed = await new.closed
        XCTAssertTrue(closed)
    }

    func testCancellationClosesOutstandingVerificationReceive() async throws {
        let transport = ScriptedSetupTransport(bootID: "one", hangVerification: true)
        let factory = SetupConnectionFactory([transport])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() })
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        let task = Task { try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: false)) }
        let start = ContinuousClock.now
        while !(await transport.methods.contains("openclaw.setup.verify")) && start.duration(to: .now) < .seconds(1) {
            await Task.yield()
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled verification must fail") } catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }

    func testNewBootIsVerifiedWithoutRequestingAnotherRestart() async throws {
        let old = ScriptedSetupTransport(bootID: "old")
        let same = ScriptedSetupTransport(bootID: "old")
        let new = ScriptedSetupTransport(bootID: "new")
        let factory = SetupConnectionFactory([old, same, new])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() }, verificationTimeout: .seconds(2))
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: true))
        let sameMethods = await same.methods
        let newMethods = await new.methods
        XCTAssertEqual(sameMethods, ["connect"])
        XCTAssertEqual(newMethods, ["connect", "openclaw.setup.verify"])
    }

    func testMissingActivationBootIdentityFailsWithoutVerification() async throws {
        let transport = ScriptedSetupTransport(bootID: nil)
        let factory = SetupConnectionFactory([transport])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() })
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        do {
            try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: true))
            XCTFail("Missing activation boot identity must fail")
        } catch {}
        let methods = await transport.methods
        XCTAssertFalse(methods.contains("openclaw.setup.verify"))
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }

    func testWrongVerifiedModelFails() async throws {
        let transport = ScriptedSetupTransport(bootID: "one", verifiedModel: "wrong/model")
        let factory = SetupConnectionFactory([transport])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() })
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        do {
            try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: false))
            XCTFail("A different verified model must fail")
        } catch {}
    }

    func testUnchangedBootIsBoundedAndNeverVerified() async throws {
        let transport = ScriptedSetupTransport(bootID: "old")
        let factory = SetupConnectionFactory([transport])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() }, verificationTimeout: .milliseconds(80))
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        let start = ContinuousClock.now
        do {
            try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: true))
            XCTFail("Unchanged boot must not finish")
        } catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let methods = await transport.methods
        XCTAssertFalse(methods.contains("openclaw.setup.verify"))
    }

    func testHungVerificationIsClosedAtDeadline() async throws {
        let transport = ScriptedSetupTransport(bootID: "old", hangVerification: true)
        let factory = SetupConnectionFactory([transport])
        let gateway = LocalModelSetupGateway(connectionFactory: { await factory.next() }, verificationTimeout: .milliseconds(80))
        _ = try await gateway.startDeviceCode(sessionID: "setup")
        let start = ContinuousClock.now
        do {
            try await gateway.verifyActivation(.init(modelRef: "test/model", gatewayRestartRequired: false))
            XCTFail("Hung verification must time out")
        } catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }
}

private actor SetupConnectionFactory {
    private var transports: [ScriptedSetupTransport]
    init(_ transports: [ScriptedSetupTransport]) { self.transports = transports }
    func next() -> OpenClawGatewayConnection {
        let transport = transports.count > 1 ? transports.removeFirst() : transports[0]
        return OpenClawGatewayConnection(transport: transport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"), pairingRetryDelay: {})
    }
}

private actor ScriptedSetupTransport: GatewayTransport {
    private let bootID: String?
    private let verifiedModel: String
    private let hangVerification: Bool
    private let hangConnect: Bool
    private let failsOpen: Bool
    private let config: Data?
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private(set) var methods: [String] = []
    private(set) var closed = false
    init(bootID: String?, verifiedModel: String = "test/model", hangVerification: Bool = false,
         hangConnect: Bool = false, failsOpen: Bool = false, config: String? = nil) {
        self.bootID = bootID; self.verifiedModel = verifiedModel; self.hangVerification = hangVerification
        self.hangConnect = hangConnect; self.failsOpen = failsOpen
        self.config = config.map { Data($0.utf8) }
    }
    func open() async throws {
        if failsOpen { throw URLError(.cannotConnectToHost) }
        closed = false
        queue.append(Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"test","ts":1}}"#.utf8))
    }
    func send(_ data: Data) async throws {
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try XCTUnwrap(frame["method"] as? String)
        methods.append(method)
        if method == "connect" && hangConnect { return }
        if method == "openclaw.setup.verify" && hangVerification { return }
        let payload: [String: Any]
        switch method {
        case "connect": payload = ["server": bootID.map { ["bootId": $0] } ?? [:]]
        case "config.get":
            payload = try XCTUnwrap(config.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        case "openclaw.setup.auth.start": payload = ["done": false, "sessionId": "setup", "status": "running"]
        case "openclaw.setup.verify":
            XCTAssertTrue((frame["params"] as? [String: Any])?.isEmpty == true)
            payload = ["ok": true, "modelRef": verifiedModel]
        default: throw NSError(domain: "Unexpected RPC \(method)", code: 1)
        }
        queue.append(try JSONSerialization.data(withJSONObject: ["type": "res", "id": frame["id"]!, "ok": true, "payload": payload]))
    }
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async {
        closed = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
