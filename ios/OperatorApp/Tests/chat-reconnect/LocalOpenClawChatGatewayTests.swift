import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

final class LocalOpenClawChatGatewayTests: XCTestCase {
    func testDeliveryEmitsMonotonicAcceptedFirstTextAndReplyTiming() async throws {
        let transport = TimingChatTransport(includeStream: true)
        let clock = TimingTestClock([100, 110, 125, 150])
        let timings = TimingEventRecorder()
        let updates = TimingDeliveryUpdates()
        let gateway = LocalOpenClawChatGateway(
            connectionFactory: {
                OpenClawGatewayConnection(
                    transport: transport,
                    token: "test",
                    identity: GatewayDeviceIdentity(),
                    metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
            },
            monotonicMilliseconds: clock.next,
            timingSink: timings.record)
        let id = UUID()

        try await gateway.deliver(
            .init(id: id, messageID: id, text: "test", idempotencyKey: "test", state: .waiting)
        ) { await updates.record($0) }

        XCTAssertEqual(timings.events, [
            .init(phase: .accepted, elapsedMilliseconds: 10),
            .init(phase: .firstText, elapsedMilliseconds: 25),
            .init(phase: .terminal, elapsedMilliseconds: 50, outcome: .reply),
        ])
        let deliveredUpdates = await updates.values
        XCTAssertEqual(deliveredUpdates, [.accepted, .working, .stream("Hello"), .reply("Hello")])
    }

    func testFinalReplyWithoutPriorReadableStreamStillEmitsFirstText() async throws {
        let transport = TimingChatTransport(includeStream: false)
        let clock = TimingTestClock([200, 205, 220])
        let timings = TimingEventRecorder()
        let gateway = LocalOpenClawChatGateway(
            connectionFactory: {
                OpenClawGatewayConnection(
                    transport: transport,
                    token: "test",
                    identity: GatewayDeviceIdentity(),
                    metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
            },
            monotonicMilliseconds: clock.next,
            timingSink: timings.record)
        let id = UUID()

        try await gateway.deliver(
            .init(id: id, messageID: id, text: "test", idempotencyKey: "test", state: .waiting)
        ) { _ in }

        XCTAssertEqual(timings.events, [
            .init(phase: .accepted, elapsedMilliseconds: 5),
            .init(phase: .firstText, elapsedMilliseconds: 20),
            .init(phase: .terminal, elapsedMilliseconds: 20, outcome: .reply),
        ])
    }

    func testSuccessfulReplyWithoutResponseRunIDStillDelivers() async throws {
        let transport = TimingChatTransport(includeStream: false, omitResponseRunID: true)
        let timings = TimingEventRecorder()
        let updates = TimingDeliveryUpdates()
        let gateway = LocalOpenClawChatGateway(
            connectionFactory: {
                OpenClawGatewayConnection(
                    transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                    metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
            },
            timingSink: timings.record)
        let id = UUID()

        try await gateway.deliver(
            .init(id: id, messageID: id, text: "test", idempotencyKey: "test", state: .waiting)
        ) { await updates.record($0) }

        let deliveredUpdates = await updates.values
        XCTAssertEqual(deliveredUpdates, [.accepted, .working, .reply("Hello")])
    }

    func testDeliveryIgnoresStaleRunEventsBeforeCurrentRequestAcknowledgement() async throws {
        let transport = TimingChatTransport(includeStream: true, includeStaleEventsBeforeAck: true)
        let updates = TimingDeliveryUpdates()
        let gateway = LocalOpenClawChatGateway(connectionFactory: {
            OpenClawGatewayConnection(
                transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
        })
        let id = UUID()

        try await gateway.deliver(
            .init(id: id, messageID: id, text: "test", idempotencyKey: "test", state: .waiting)
        ) { await updates.record($0) }

        let deliveredUpdates = await updates.values
        XCTAssertEqual(deliveredUpdates, [.accepted, .working, .stream("Hello"), .reply("Hello")])
    }

    func testTerminalOKRecoversOnlyExactRunReplyWithoutSendingChatAgain() async throws {
        let transport = TimingChatTransport(
            includeStream: false,
            terminalStatus: "ok",
            historyMessages: [
                #"{"role":"assistant","content":[{"type":"text","text":"Unrelated latest"}],"__openclaw":{"idempotencyKey":"other-run"}}"#,
                #"{"role":"assistant","content":[{"type":"text","text":"Recovered exact reply"}],"__openclaw":{"idempotencyKey":"run"}}"#,
            ])
        let updates = TimingDeliveryUpdates()
        let gateway = LocalOpenClawChatGateway(connectionFactory: {
            OpenClawGatewayConnection(
                transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
        })
        let id = UUID()

        try await gateway.deliver(
            .init(id: id, messageID: id, text: "test", idempotencyKey: "run", state: .waiting)
        ) { await updates.record($0) }

        let recordedUpdates = await updates.values
        let chatSendCount = await transport.chatSendCount
        let methods = await transport.methods
        XCTAssertEqual(recordedUpdates, [.accepted, .reply("Recovered exact reply")])
        XCTAssertEqual(chatSendCount, 1)
        XCTAssertEqual(methods, ["connect", "chat.history", "chat.send", "chat.history"])
    }

    func testReopeningRecoversSavedCompletionBeforeSendingRequestAgain() async throws {
        let transport = TimingChatTransport(
            includeStream: false,
            historyMessages: [
                #"{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Already opened"}],"__openclaw":{"runId":"run"}}"#,
            ],
            historyAvailableBeforeSend: true)
        let updates = TimingDeliveryUpdates()
        let gateway = LocalOpenClawChatGateway(connectionFactory: {
            OpenClawGatewayConnection(
                transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
        })
        let id = UUID()
        try await gateway.deliver(
            .init(id: id, messageID: id, text: "Open website", idempotencyKey: "run", state: .waiting)
        ) { await updates.record($0) }
        let values = await updates.values
        let methods = await transport.methods
        XCTAssertEqual(values, [.accepted, .reply("Already opened")])
        XCTAssertEqual(methods, ["connect", "chat.history"])
    }

    func testNativeRecoveryPendingKeepsRequestRetryableBeforeSendAndAfterEarlyFailure() async throws {
        for beforeSend in [true, false] {
            let transport = TimingChatTransport(
                includeStream: false, outcome: .failed,
                historyAvailableBeforeSend: beforeSend, recoverySourceRunID: "run")
            let updates = TimingDeliveryUpdates()
            let gateway = LocalOpenClawChatGateway(connectionFactory: {
                OpenClawGatewayConnection(
                    transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                    metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
            })
            let id = UUID()
            do {
                try await gateway.deliver(
                    .init(id: id, messageID: id, text: "Read only", idempotencyKey: "run", state: .waiting)
                ) { await updates.record($0) }
                XCTFail("Pending native recovery must retain the request for retry")
            } catch {
                guard case ChatGatewayError.gateway("Operator is restoring this request.") = error else {
                    return XCTFail("Expected a recoverable native-recovery status, got \(error)")
                }
            }
            let values = await updates.values
            XCTAssertFalse(values.contains { if case .failed = $0 { return true }; return false })
            let sendCount = await transport.chatSendCount
            XCTAssertEqual(sendCount, beforeSend ? 0 : 1)
        }
    }

    func testTerminalOKWithUnknownOrEmptyExactHistoryDoesNotUseUnrelatedReply() async throws {
        for messages in [
            [#"{"role":"assistant","content":[{"type":"text","text":"Wrong"}],"__openclaw":{"idempotencyKey":"other-run"}}"#],
            [#"{"role":"assistant","content":[],"__openclaw":{"idempotencyKey":"run"}}"#],
        ] {
            let transport = TimingChatTransport(
                includeStream: false, terminalStatus: "ok", historyMessages: messages)
            let updates = TimingDeliveryUpdates()
            let gateway = LocalOpenClawChatGateway(connectionFactory: {
                OpenClawGatewayConnection(
                    transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                    metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
            })
            let id = UUID()
            try await gateway.deliver(
                .init(id: id, messageID: id, text: "test", idempotencyKey: "run", state: .waiting)
            ) { await updates.record($0) }
            let recordedUpdates = await updates.values
            let chatSendCount = await transport.chatSendCount
            XCTAssertEqual(
                recordedUpdates,
                [.accepted, .failed("Operator finished, but its exact reply could not be recovered.")])
            XCTAssertEqual(chatSendCount, 1)
        }
    }

    func testTerminalErrorAndTimeoutFinishWithoutHistoryOrDuplicateSend() async throws {
        for status in ["error", "timeout"] {
            let transport = TimingChatTransport(includeStream: false, terminalStatus: status)
            let updates = TimingDeliveryUpdates()
            let gateway = LocalOpenClawChatGateway(connectionFactory: {
                OpenClawGatewayConnection(
                    transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                    metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
            })
            let id = UUID()
            try await gateway.deliver(
                .init(id: id, messageID: id, text: "test", idempotencyKey: "run", state: .waiting)
            ) { await updates.record($0) }
            let recordedUpdates = await updates.values
            let chatSendCount = await transport.chatSendCount
            let methods = await transport.methods
            XCTAssertEqual(recordedUpdates, [.accepted, .failed("Operator could not complete this request.")])
            XCTAssertEqual(chatSendCount, 1)
            XCTAssertEqual(methods, ["connect", "chat.history", "chat.send"])
        }
    }

    func testFailedStoppedAndTransportErrorRecordFixedTerminalOutcomes() async throws {
        for expected in [
            (TimingChatTransport.Outcome.failed, LocalChatDeliveryTimingEvent.Outcome.failed),
            (.stopped, .stopped),
            (.transportError, .error),
        ] {
            let transport = TimingChatTransport(includeStream: false, outcome: expected.0)
            let clock = TimingTestClock([300, 305, 320])
            let timings = TimingEventRecorder()
            let gateway = LocalOpenClawChatGateway(
                connectionFactory: {
                    OpenClawGatewayConnection(
                        transport: transport,
                        token: "test",
                        identity: GatewayDeviceIdentity(),
                        metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
                },
                monotonicMilliseconds: clock.next,
                timingSink: timings.record)
            let id = UUID()

            do {
                try await gateway.deliver(
                    .init(
                        id: id, messageID: id, text: "test", idempotencyKey: "test",
                        state: .waiting)
                ) { _ in }
            } catch {
                XCTAssertEqual(expected.0, .transportError)
            }

            XCTAssertEqual(timings.events.last?.phase, .terminal)
            XCTAssertEqual(timings.events.last?.outcome, expected.1)
            XCTAssertEqual(timings.events.filter { $0.phase == .accepted }.count, 1)
            XCTAssertEqual(timings.events.filter { $0.phase == .firstText }.count, 0)
        }
    }

    func testFailedDecisionConnectionClosesWithoutClosingChatAndAllowsRecovery() async throws {
        let chat = ChatTestTransport(approvalID: "approval")
        let control = ChatTestTransport(approvalID: "approval")
        let fresh = ChatTestTransport(approvalID: "approval")
        await control.makeStale()
        let factory = ChatConnectionFactory([chat, control, fresh])
        let gateway = LocalOpenClawChatGateway(connectionFactory: { await factory.next() })
        try await gateway.activateApprovalUpdates { _ in }
        do {
            _ = try await gateway.resolveApproval(id: "approval", kind: .exec, decision: .deny)
            XCTFail("Failed decision connection must not report success")
        } catch {}
        let chatClosed = await chat.closed
        let controlClosed = await control.closed
        XCTAssertFalse(chatClosed)
        XCTAssertTrue(controlClosed)
        try await gateway.activateApprovalUpdates { _ in }
        let freshMethods = await fresh.methods
        XCTAssertEqual(freshMethods, ["connect", "sessions.messages.subscribe"])
    }

    func testStopWhileLiveApprovalPendingConsumesServerCancellation() async throws {
        let transport = TerminalApprovalTransport(waitForStop: true)
        let gateway = LocalOpenClawChatGateway(connectionFactory: {
            OpenClawGatewayConnection(transport: transport, token: "test", identity: GatewayDeviceIdentity(),
                metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
        })
        let observations = TerminalApprovalObservations()
        try await gateway.activateApprovalUpdates { await observations.record(approval: $0) }
        let id = UUID()
        let delivery = Task {
            try await gateway.deliver(.init(id: id, messageID: id, text: "test", idempotencyKey: "test", state: .waiting)) {
                await observations.record(delivery: $0)
            }
        }
        let pendingDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await observations.sawPending) && ContinuousClock.now < pendingDeadline { await Task.yield() }
        let pending = await observations.sawPending
        XCTAssertTrue(pending)
        await gateway.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await observations.sawStopped) && ContinuousClock.now < deadline { await Task.yield() }
        let stopped = await observations.sawStopped
        let terminal = await observations.sawTerminal
        XCTAssertTrue(stopped)
        XCTAssertTrue(terminal)
        if !stopped { await transport.close() }
        try await delivery.value
    }

    func testSubscriptionOwnsConnectionUntilReplayCompletes() async throws {
        let transport = ChatTestTransport(approvalID: "approval", holdSubscription: true)
        let factory = ChatConnectionFactory([transport])
        let gateway = LocalOpenClawChatGateway(connectionFactory: { await factory.next() })
        let activation = Task { try await gateway.activateApprovalUpdates { _ in } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await transport.hasHeldResponse()) && ContinuousClock.now < deadline { await Task.yield() }
        do {
            _ = try await gateway.resolveApproval(id: "approval", kind: .exec, decision: .deny)
            XCTFail("Approval must not consume an outstanding subscription response")
        } catch {}
        let id = UUID()
        do {
            try await gateway.deliver(.init(id: id, messageID: id, text: "test", idempotencyKey: "test", state: .waiting)) { _ in }
            XCTFail("Delivery must wait for subscription readiness")
        } catch {}
        let methods = await transport.methods
        XCTAssertEqual(methods, ["connect", "sessions.messages.subscribe"])
        await transport.finishHeldResponse()
        try await activation.value
    }

    func testReactivationDoesNotCloseConnectionOwnedByApprovalResolution() async throws {
        let transport = ChatTestTransport(approvalID: "approval")
        let control = ChatTestTransport(approvalID: "approval")
        let factory = ChatConnectionFactory([transport, control])
        let gateway = LocalOpenClawChatGateway(connectionFactory: { await factory.next() })
        try await gateway.activateApprovalUpdates { _ in }
        let resolution = Task { try await gateway.resolveApproval(id: "approval", kind: .exec, decision: .deny) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            let chatHeld = await transport.hasHeldResponse()
            let controlHeld = await control.hasHeldResponse()
            if chatHeld || controlHeld { break }
            await Task.yield()
        }
        do {
            try await gateway.activateApprovalUpdates { _ in }
            XCTFail("Reconnect must defer while an approval response is outstanding")
        } catch {}
        let closed = await transport.closed
        XCTAssertFalse(closed)
        let chatMethods = await transport.methods
        let controlMethods = await control.methods
        XCTAssertEqual(chatMethods, ["connect", "sessions.messages.subscribe"])
        XCTAssertEqual(controlMethods, ["connect", "approval.resolve"])
        await transport.finishHeldResponse()
        await control.finishHeldResponse()
        let result = try await resolution.value
        XCTAssertEqual(result.status, .denied)
        let controlClosed = await control.closed
        XCTAssertTrue(controlClosed)
    }

    func testReactivationUsesFreshTransportAndReplaysApprovals() async throws {
        let old = ChatTestTransport(approvalID: "old-approval")
        let fresh = ChatTestTransport(approvalID: "fresh-approval")
        let factory = ChatConnectionFactory([old, fresh])
        let gateway = LocalOpenClawChatGateway(connectionFactory: { await factory.next() })
        let replays = ChatReplays()
        try await gateway.activateApprovalUpdates { await replays.record($0) }
        await old.makeStale()

        try await gateway.activateApprovalUpdates { await replays.record($0) }

        let oldMethods = await old.methods
        let freshMethods = await fresh.methods
        let closed = await old.closed
        let ids = await replays.ids
        XCTAssertTrue(closed)
        XCTAssertEqual(oldMethods, ["connect", "sessions.messages.subscribe"])
        XCTAssertEqual(freshMethods, ["connect", "sessions.messages.subscribe"])
        XCTAssertEqual(ids, [["old-approval"], ["fresh-approval"]])
    }

    func testServerTerminalApprovalLetsDeliveryConsumeFinalFailureWithoutLocalDecision() async throws {
        let transport = TerminalApprovalTransport()
        let gateway = LocalOpenClawChatGateway(connectionFactory: {
            OpenClawGatewayConnection(
                transport: transport,
                token: "test",
                identity: GatewayDeviceIdentity(),
                metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
        })
        let observations = TerminalApprovalObservations()
        try await gateway.activateApprovalUpdates { await observations.record(approval: $0) }
        let id = UUID()
        let delivery = Task {
            try await gateway.deliver(.init(
                id: id,
                messageID: id,
                text: "test",
                idempotencyKey: "test",
                state: .waiting)) { await observations.record(delivery: $0) }
        }

        let pendingDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await observations.sawPending) && ContinuousClock.now < pendingDeadline {
            await Task.yield()
        }
        let sawPending = await observations.sawPending
        XCTAssertTrue(sawPending, "The live pending approval must be published first")

        let terminalDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await observations.completed)
            && ContinuousClock.now < terminalDeadline
        {
            await Task.yield()
        }
        let consumedWithoutLocalDecision = await observations.completed
        XCTAssertTrue(
            consumedWithoutLocalDecision,
            "A server-terminal approval must release delivery so its final failure is consumed")

        if !consumedWithoutLocalDecision {
            _ = try await gateway.resolveApproval(id: "approval", kind: .exec, decision: .deny)
        }
        try await delivery.value
    }
}

private final class TimingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]

    init(_ values: [Double]) { self.values = values }

    func next() -> Double {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.removeFirst()
    }
}

private final class TimingEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LocalChatDeliveryTimingEvent] = []

    var events: [LocalChatDeliveryTimingEvent] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    func record(_ event: LocalChatDeliveryTimingEvent) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.recorded.append(event)
    }
}

private actor TimingDeliveryUpdates {
    private(set) var values: [ChatDeliveryUpdate] = []
    func record(_ update: ChatDeliveryUpdate) { self.values.append(update) }
}

private actor TimingChatTransport: GatewayTransport {
    enum Outcome: Equatable {
        case reply
        case failed
        case stopped
        case transportError
    }

    private let includeStream: Bool
    private let outcome: Outcome
    private var queue: [Data] = []

    private let omitResponseRunID: Bool
    private let includeStaleEventsBeforeAck: Bool
    private let terminalStatus: String?
    private let historyMessages: [String]
    private let historyAvailableBeforeSend: Bool
    private let recoverySourceRunID: String?
    private(set) var methods: [String] = []
    private(set) var chatSendCount = 0

    init(
        includeStream: Bool,
        outcome: Outcome = .reply,
        omitResponseRunID: Bool = false,
        includeStaleEventsBeforeAck: Bool = false,
        terminalStatus: String? = nil,
        historyMessages: [String] = [],
        historyAvailableBeforeSend: Bool = false,
        recoverySourceRunID: String? = nil)
    {
        self.includeStream = includeStream
        self.outcome = outcome
        self.omitResponseRunID = omitResponseRunID
        self.includeStaleEventsBeforeAck = includeStaleEventsBeforeAck
        self.terminalStatus = terminalStatus
        self.historyMessages = historyMessages
        self.historyAvailableBeforeSend = historyAvailableBeforeSend
        self.recoverySourceRunID = recoverySourceRunID
    }

    func open() {
        self.queue.append(Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"test","ts":1}}"#.utf8))
    }

    func send(_ data: Data) throws {
        let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = frame?["id"] as? String ?? "missing"
        let method = frame?["method"] as? String ?? "missing"
        self.methods.append(method)
        switch method {
        case "connect":
            self.queue.append(Data(#"{"type":"res","id":"\#(id)","ok":true,"payload":{}}"#.utf8))
        case "chat.send":
            self.chatSendCount += 1
            self.queue.append(Data(#"{"type":"res","id":"unrelated","ok":true,"payload":{}}"#.utf8))
            if self.includeStaleEventsBeforeAck {
                self.queue.append(Data(#"{"type":"event","event":"chat","payload":{"runId":"old-run","sessionKey":"agent:main:main","seq":1,"state":"delta","deltaText":"Stale"}}"#.utf8))
                self.queue.append(Data(#"{"type":"event","event":"chat","payload":{"runId":"old-run","sessionKey":"agent:main:main","seq":2,"state":"final","message":"Stale interrupted reply"}}"#.utf8))
            }
            let responseStatus = self.terminalStatus ?? "started"
            let responsePayload = self.omitResponseRunID
                ? #"{"status":"\#(responseStatus)"}"#
                : #"{"runId":"run","status":"\#(responseStatus)"}"#
            self.queue.append(Data(#"{"type":"res","id":"\#(id)","ok":true,"payload":\#(responsePayload)}"#.utf8))
            if self.terminalStatus != nil { return }
            if self.outcome == .transportError {
                return
            } else if self.outcome == .failed {
                self.queue.append(Data(#"{"type":"event","event":"chat","payload":{"runId":"run","sessionKey":"agent:main:main","seq":1,"state":"error","errorMessage":"fixed failure"}}"#.utf8))
            } else if self.outcome == .stopped {
                self.queue.append(Data(#"{"type":"event","event":"chat","payload":{"runId":"run","sessionKey":"agent:main:main","seq":1,"state":"aborted"}}"#.utf8))
            } else if self.includeStream {
                let runID = self.omitResponseRunID ? "test" : "run"
                self.queue.append(Data(#"{"type":"event","event":"chat","payload":{"runId":"\#(runID)","sessionKey":"agent:main:main","seq":1,"state":"delta","deltaText":"Hello"}}"#.utf8))
                self.queue.append(Data(#"{"type":"event","event":"chat","payload":{"runId":"\#(runID)","sessionKey":"agent:main:main","seq":2,"state":"final","message":"Hello"}}"#.utf8))
            } else {
                let runID = self.omitResponseRunID ? "test" : "run"
                self.queue.append(Data(#"{"type":"event","event":"chat","payload":{"runId":"\#(runID)","sessionKey":"agent:main:main","seq":1,"state":"final","message":"Hello"}}"#.utf8))
            }
        case "chat.history":
            let messages = (self.historyAvailableBeforeSend || self.chatSendCount > 0
                ? self.historyMessages : []).joined(separator: ",")
            let recovery = (self.historyAvailableBeforeSend || self.chatSendCount > 0)
                ? self.recoverySourceRunID.map { #","operatorRecovery":{"sourceRunId":"\#($0)","runId":"recovery"}"# } ?? ""
                : ""
            self.queue.append(Data(#"{"type":"res","id":"\#(id)","ok":true,"payload":{"messages":[\#(messages)]\#(recovery)}}"#.utf8))
        default:
            throw NSError(domain: "Unexpected RPC", code: 1)
        }
    }

    func receive() throws -> Data {
        guard !self.queue.isEmpty else { throw URLError(.networkConnectionLost) }
        return self.queue.removeFirst()
    }

    func close() {}
}

private actor TerminalApprovalObservations {
    private(set) var sawPending = false
    private(set) var sawTerminal = false
    private(set) var sawFailure = false
    private(set) var sawStopped = false
    var completed: Bool { sawTerminal && sawFailure }
    func record(approval: ChatApprovalUpdate) {
        guard case let .event(event) = approval else { return }
        if event.phase == .pending { self.sawPending = true }
        if event.phase == .terminal { self.sawTerminal = true }
    }
    func record(delivery: ChatDeliveryUpdate) {
        if case .failed = delivery { self.sawFailure = true }
        if case .stopped = delivery { self.sawStopped = true }
    }
}

private actor TerminalApprovalTransport: GatewayTransport {
    private let waitForStop: Bool
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?

    init(waitForStop: Bool = false) { self.waitForStop = waitForStop }

    func open() {
        self.queue.append(Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"test","ts":1}}"#.utf8))
    }

    func send(_ data: Data) async throws {
        let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = frame?["id"] as? String ?? "missing"
        let method = frame?["method"] as? String
        let response: String
        switch method {
        case "connect":
            response = #"{"type":"res","id":"\#(id)","ok":true,"payload":{}}"#
        case "sessions.messages.subscribe":
            response = #"{"type":"res","id":"\#(id)","ok":true,"payload":{"subscribed":true,"key":"agent:main:main","approvalReplay":{"sessionKey":"agent:main:main","updatedAtMs":1,"approvals":[],"truncated":false}}}"#
        case "chat.history":
            response = #"{"type":"res","id":"\#(id)","ok":true,"payload":{"messages":[]}}"#
        case "chat.send":
            response = #"{"type":"res","id":"\#(id)","ok":true,"payload":{"runId":"run","status":"started"}}"#
            self.enqueue(Self.approvalEvent(phase: "pending", status: "pending"))
            if !self.waitForStop {
                self.enqueue(Self.approvalEvent(phase: "terminal", status: "cancelled"))
                self.enqueue(Data(#"{"type":"event","event":"chat","payload":{"runId":"run","sessionKey":"agent:main:main","seq":1,"state":"error","errorMessage":"Approval was cancelled"}}"#.utf8))
            }
        case "chat.abort":
            response = #"{"type":"res","id":"\#(id)","ok":true,"payload":{}}"#
            self.enqueue(Self.approvalEvent(phase: "terminal", status: "cancelled"))
            self.enqueue(Data(#"{"type":"event","event":"chat","payload":{"runId":"run","sessionKey":"agent:main:main","seq":1,"state":"aborted"}}"#.utf8))
        case "approval.resolve":
            response = #"{"type":"res","id":"\#(id)","ok":true,"payload":{"applied":true,"approval":{"id":"approval","createdAtMs":1,"expiresAtMs":9999999999999,"resolvedAtMs":2,"reason":"test-cleanup","decision":"deny","status":"denied","presentation":{"kind":"exec","commandText":"test","allowedDecisions":["deny"]}}}}"#
        default:
            throw NSError(domain: "Unexpected RPC", code: 1)
        }
        self.enqueue(Data(response.utf8), beforeQueuedEvents: method == "chat.send")
    }

    func receive() async throws -> Data {
        if !self.queue.isEmpty { return self.queue.removeFirst() }
        return try await withCheckedThrowingContinuation { self.waiter = $0 }
    }

    func close() {
        self.waiter?.resume(throwing: CancellationError())
        self.waiter = nil
    }

    private func enqueue(_ data: Data, beforeQueuedEvents: Bool = false) {
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else if beforeQueuedEvents {
            self.queue.insert(data, at: 0)
        } else {
            self.queue.append(data)
        }
    }

    private static func approvalEvent(phase: String, status: String) -> Data {
        Data(#"{"type":"event","event":"session.approval","payload":{"sessionKey":"agent:main:main","updatedAtMs":2,"phase":"\#(phase)","approval":{"id":"approval","createdAtMs":1,"expiresAtMs":9999999999999,"status":"\#(status)","presentation":{"kind":"exec","commandText":"test","allowedDecisions":["deny"]}}}}"#.utf8)
    }
}

private actor ChatReplays {
    private(set) var ids: [[String]] = []
    func record(_ update: ChatApprovalUpdate) {
        if case let .replay(replay) = update { ids.append(replay.approvals.map(\.id)) }
    }
}
private actor ChatConnectionFactory {
    private var transports: [ChatTestTransport]
    init(_ transports: [ChatTestTransport]) { self.transports = transports }
    func next() -> OpenClawGatewayConnection {
        let transport = transports.removeFirst()
        return OpenClawGatewayConnection(transport: transport, token: "test", identity: GatewayDeviceIdentity(),
            metadata: .init(appVersion: "test", platform: "test", instanceID: "test"))
    }
}
private actor ChatTestTransport: GatewayTransport {
    private let approvalID: String
    private let holdSubscription: Bool
    private var queue: [Data] = []
    private var stale = false
    private var heldResponse: Data?
    private var waiter: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    private(set) var methods: [String] = []
    init(approvalID: String, holdSubscription: Bool = false) {
        self.approvalID = approvalID
        self.holdSubscription = holdSubscription
    }
    func makeStale() { stale = true }
    func hasHeldResponse() -> Bool { heldResponse != nil }
    func finishHeldResponse() {
        if let heldResponse {
            if let waiter { waiter.resume(returning: heldResponse); self.waiter = nil }
            else { queue.append(heldResponse) }
            self.heldResponse = nil
        }
    }
    func open() async throws {
        queue.append(Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"test","ts":1}}"#.utf8))
    }
    func send(_ data: Data) async throws {
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try XCTUnwrap(frame["method"] as? String)
        methods.append(method)
        if stale { throw URLError(.networkConnectionLost) }
        let payload: [String: Any]
        switch method {
        case "connect": payload = [:]
        case "sessions.messages.subscribe":
            payload = ["subscribed": true, "key": "agent:main:main", "approvalReplay": [
                "sessionKey": "agent:main:main", "updatedAtMs": 1, "truncated": false,
                "approvals": [["id": approvalID, "createdAtMs": 1, "expiresAtMs": 9999999999999,
                               "status": "pending", "presentation": ["kind": "exec", "commandText": "test", "allowedDecisions": ["deny"]]]]]]
        case "approval.resolve":
            payload = ["applied": true, "approval": ["id": approvalID, "createdAtMs": 1, "expiresAtMs": 9999999999999,
                "resolvedAtMs": 2, "reason": "user", "decision": "deny", "status": "denied",
                "presentation": ["kind": "exec", "commandText": "test", "allowedDecisions": ["deny"]]]]
        default: throw NSError(domain: "Unexpected RPC", code: 1)
        }
        let response = try JSONSerialization.data(withJSONObject: ["type": "res", "id": frame["id"]!, "ok": true, "payload": payload])
        if method == "approval.resolve" || (method == "sessions.messages.subscribe" && holdSubscription) { heldResponse = response }
        else { queue.append(response) }
    }
    func receive() async throws -> Data {
        if queue.isEmpty && heldResponse != nil {
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
        guard !queue.isEmpty else { throw URLError(.networkConnectionLost) }
        return queue.removeFirst()
    }
    func close() async {
        closed = true
        waiter?.resume(throwing: URLError(.networkConnectionLost))
        waiter = nil
    }
}
