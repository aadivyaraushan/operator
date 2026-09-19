import Foundation
import XCTest
import OperatorCore
@testable import OperatorApp

@MainActor
final class WhatsAppLinkFlowTests: XCTestCase {
    func testSafeFailureReasonReachesScreenWithoutRawDetails() async throws {
        for (code, text) in [
            ("verification_required", "WhatsApp requires extra verification that this connection cannot complete yet."),
            ("code_expired", "This link code expired. Try again to request a new one."),
            ("client_outdated", "The WhatsApp connection needs an update before it can link."),
            ("private-token", "WhatsApp could not finish linking. Try again or check your connection."),
        ] {
            let value = try JSONDecoder().decode(WhatsAppLinkStatus.self, from: Data(
                "{\"operationId\":\"op-1\",\"phase\":\"failed\",\"failureCode\":\"\(code)\"}".utf8))
            let gateway = WhatsAppLinkGatewayStub(starts: [operation(.waitingForCode)], statuses: [value])
            let model = WhatsAppLinkFlowModel(gateway: gateway)
            await model.start(phone: "+15551234567")
            await model.refresh()
            XCTAssertEqual(model.state, .failed)
            XCTAssertEqual(model.failureMessage, text)
            XCTAssertNil(model.pairCode)
        }
    }
    func testFormattedNumbersReachGatewayAsInternationalDigits() async throws {
        for phone in [" +1 (555) 123-4567 ", "+1.555.123.4567", "+1\u{00a0}555\u{202f}123‑4567"] {
            let gateway = WhatsAppLinkGatewayStub(starts: [operation(.waitingForCode)])
            let model = WhatsAppLinkFlowModel(gateway: gateway)
            await model.start(phone: phone)
            let sent = await gateway.startedPhones()
            XCTAssertEqual(sent, ["+15551234567"])
        }
    }

    func testInvalidOrAmbiguousNumbersNeverReachGateway() async throws {
        for phone in ["555 123 4567", "+1 555 CALL NOW", "+1 555 123 4567 ext 2", "++15551234567", "+0123456789", "+123", "+1234567890123456"] {
            let gateway = WhatsAppLinkGatewayStub(starts: [operation(.waitingForCode)])
            let model = WhatsAppLinkFlowModel(gateway: gateway)
            await model.start(phone: phone)
            let sent = await gateway.startedPhones()
            XCTAssertTrue(sent.isEmpty, "Invalid or ambiguous input must not start pairing")
            XCTAssertEqual(model.state, .idle)
        }
    }

    func testStartSendsPhoneWithoutRetainingItAndWaitsForCode() async throws {
        let gateway = WhatsAppLinkGatewayStub(starts: [operation(.waitingForCode)])
        let model = WhatsAppLinkFlowModel(gateway: gateway)

        await model.start(phone: "+15551234567")

        XCTAssertEqual(model.state, .waitingForCode)
        XCTAssertEqual(model.operationID, "op-1")
        XCTAssertNil(model.pairCode)
        let startedPhones = await gateway.startedPhones()
        XCTAssertEqual(startedPhones, ["+15551234567"])
    }

    func testBackgroundClearsCodeWithoutCancellingAndForegroundRefreshes() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            statuses: [
                status(.codeReady, pairCode: "ABCD-1234"),
                status(.codeReady, pairCode: "WXYZ-9876"),
            ])
        let model = WhatsAppLinkFlowModel(gateway: gateway)
        await model.start(phone: "+15551234567")
        await model.refresh()
        XCTAssertEqual(model.state, .codeReady)
        XCTAssertEqual(model.pairCode, "ABCD-1234")

        await model.setForegroundActive(false)

        XCTAssertEqual(model.state, .waitingForCode)
        XCTAssertNil(model.pairCode)
        XCTAssertEqual(model.operationID, "op-1")
        let cancelledWhileBackground = await gateway.cancelledOperationIDs()
        XCTAssertEqual(cancelledWhileBackground, [])

        await model.setForegroundActive(true)

        XCTAssertEqual(model.state, .codeReady)
        XCTAssertEqual(model.pairCode, "WXYZ-9876")
        let cancelledAfterForeground = await gateway.cancelledOperationIDs()
        XCTAssertEqual(cancelledAfterForeground, [])
    }

    func testStaleStatusCannotReviveCodeAfterBackground() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            statuses: [status(.codeReady, pairCode: "ABCD-1234")],
            holdStatus: true)
        let model = WhatsAppLinkFlowModel(gateway: gateway)
        await model.start(phone: "+15551234567")

        let refresh = Task { await model.refresh() }
        for _ in 0 ..< 100 where await gateway.statusRequestCount() == 0 { await Task.yield() }
        await model.setForegroundActive(false)
        await gateway.releaseStatus()
        await refresh.value

        XCTAssertEqual(model.state, .waitingForCode)
        XCTAssertNil(model.pairCode)
        XCTAssertEqual(model.operationID, "op-1")
    }

    func testExplicitCancelCallsGatewayAndClosesFlow() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            cancellations: [operation(.cancelled)])
        let model = WhatsAppLinkFlowModel(gateway: gateway)
        await model.start(phone: "+15551234567")

        await model.cancel()

        let cancelled = await gateway.cancelledOperationIDs()
        XCTAssertEqual(cancelled, ["op-1"])
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertNil(model.pairCode)
        XCTAssertNil(model.operationID)
        XCTAssertFalse(model.isPresented)
    }

    func testCancelDuringPendingStartCancelsReturnedOperationWithoutRevivingTheSheet() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            cancellations: [operation(.cancelled)],
            holdStart: true)
        let model = WhatsAppLinkFlowModel(gateway: gateway)

        let start = Task { await model.start(phone: "+15551234567") }
        for _ in 0 ..< 100 where await gateway.startedPhones().isEmpty { await Task.yield() }
        await model.cancel()
        await gateway.releaseStart()
        await start.value

        let cancelled = await gateway.cancelledOperationIDs()
        XCTAssertEqual(cancelled, ["op-1"])
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertNil(model.pairCode)
        XCTAssertNil(model.operationID)
        XCTAssertFalse(model.isPresented)
    }

    func testTerminalStatusClearsCodeAndOperationID() async throws {
        let terminalPhases: [WhatsAppLinkPhase] = [.cancelled, .failed, .linked]
        for phase in terminalPhases {
            let gateway = WhatsAppLinkGatewayStub(
                starts: [operation(.waitingForCode)],
                statuses: [
                    status(.codeReady, pairCode: "ABCD-1234"),
                    status(phase),
                ])
            let model = WhatsAppLinkFlowModel(gateway: gateway)
            await model.start(phone: "+15551234567")
            await model.refresh()
            await model.refresh()

            XCTAssertEqual(model.state.phase, phase)
            XCTAssertNil(model.pairCode)
            XCTAssertNil(model.operationID)
        }
    }

    func testForegroundPollingShowsCodeWithoutLeavingTheSheet() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            statuses: [status(.codeReady, pairCode: "ABCD-1234")])
        let model = WhatsAppLinkFlowModel(gateway: gateway, pollInterval: .milliseconds(1))

        await model.start(phone: "+15551234567")
        await waitUntil { model.pairCode == "ABCD-1234" }

        XCTAssertEqual(model.state, .codeReady)
        XCTAssertEqual(model.pairCode, "ABCD-1234")
    }

    func testPollingContinuesFromFinishingToLinkedThenStops() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            statuses: [status(.finishing), status(.linked)])
        let model = WhatsAppLinkFlowModel(gateway: gateway, pollInterval: .milliseconds(1))

        await model.start(phone: "+15551234567")
        await waitUntil { model.state == .linked }
        let requestsAtLink = await gateway.statusRequestCount()
        try? await Task.sleep(for: .milliseconds(10))
        let requestsAfterWait = await gateway.statusRequestCount()

        XCTAssertEqual(requestsAtLink, 2)
        XCTAssertEqual(requestsAfterWait, requestsAtLink)
        XCTAssertNil(model.pairCode)
    }

    func testBackgroundStopsPollingAndForegroundResumesIt() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            statuses: [status(.codeReady, pairCode: "ABCD-1234")])
        let model = WhatsAppLinkFlowModel(gateway: gateway, pollInterval: .milliseconds(1))

        await model.start(phone: "+15551234567")
        await waitUntil { model.pairCode == "ABCD-1234" }
        await model.setForegroundActive(false)
        let requestsAtBackground = await gateway.statusRequestCount()
        await model.refresh()
        try? await Task.sleep(for: .milliseconds(10))
        let requestsWhileBackground = await gateway.statusRequestCount()

        XCTAssertNil(model.pairCode)
        XCTAssertEqual(requestsWhileBackground, requestsAtBackground)

        await model.setForegroundActive(true)
        await waitUntil { model.pairCode == "ABCD-1234" }
        let requestsAfterForeground = await gateway.statusRequestCount()
        XCTAssertEqual(model.state, .codeReady)
        XCTAssertGreaterThan(requestsAfterForeground, requestsWhileBackground)
    }

    func testLateCancelFromPreviousOperationCannotReplaceNewStart() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode), operation(.waitingForCode, operationID: "op-2")],
            cancellations: [operation(.cancelled)],
            holdCancel: true)
        let model = WhatsAppLinkFlowModel(gateway: gateway)
        await model.start(phone: "+15551234567")

        let cancel = Task { await model.cancel() }
        for _ in 0 ..< 100 where await gateway.cancelledOperationIDs().isEmpty { await Task.yield() }
        await model.start(phone: "+15557654321")
        await gateway.releaseCancel()
        await cancel.value

        XCTAssertEqual(model.operationID, "op-2")
        XCTAssertEqual(model.state, .waitingForCode)
        XCTAssertTrue(model.isPresented)
    }

    func testCancelStopsForegroundPolling() async throws {
        let gateway = WhatsAppLinkGatewayStub(
            starts: [operation(.waitingForCode)],
            statuses: [status(.codeReady, pairCode: "ABCD-1234")],
            cancellations: [operation(.cancelled)])
        let model = WhatsAppLinkFlowModel(gateway: gateway, pollInterval: .milliseconds(1))

        await model.start(phone: "+15551234567")
        await waitUntil { model.pairCode == "ABCD-1234" }
        await model.cancel()
        let requestsAtCancel = await gateway.statusRequestCount()
        try? await Task.sleep(for: .milliseconds(10))
        let requestsAfterWait = await gateway.statusRequestCount()

        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(requestsAfterWait, requestsAtCancel)
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line) async
{
    for _ in 0 ..< 100 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "timed out waiting for condition", file: file, line: line)
}

private func operation(_ phase: WhatsAppLinkPhase, operationID: String = "op-1") -> WhatsAppLinkOperation {
    try! JSONDecoder().decode(
        WhatsAppLinkOperation.self,
        from: Data("{\"operationId\":\"\(operationID)\",\"phase\":\"\(phase.rawValue)\"}".utf8))
}

private func status(_ phase: WhatsAppLinkPhase, pairCode: String? = nil) -> WhatsAppLinkStatus {
    let code = pairCode.map { ",\"pairCode\":\"\($0)\"" } ?? ""
    return try! JSONDecoder().decode(
        WhatsAppLinkStatus.self,
        from: Data("{\"operationId\":\"op-1\",\"phase\":\"\(phase.rawValue)\"\(code)}".utf8))
}

private actor WhatsAppLinkGatewayStub: WhatsAppLinkFlowGateway {
    private var starts: [WhatsAppLinkOperation]
    private var statuses: [WhatsAppLinkStatus]
    private var cancellations: [WhatsAppLinkOperation]
    private var phones: [String] = []
    private var cancelled: [String] = []
    private var statusRequests = 0
    private var holdStart: Bool
    private var holdStatus: Bool
    private var holdCancel: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var statusContinuation: CheckedContinuation<Void, Never>?
    private var cancelContinuation: CheckedContinuation<Void, Never>?

    init(
        starts: [WhatsAppLinkOperation],
        statuses: [WhatsAppLinkStatus] = [],
        cancellations: [WhatsAppLinkOperation] = [],
        holdStart: Bool = false,
        holdStatus: Bool = false,
        holdCancel: Bool = false)
    {
        self.starts = starts
        self.statuses = statuses
        self.cancellations = cancellations
        self.holdStart = holdStart
        self.holdStatus = holdStatus
        self.holdCancel = holdCancel
    }

    func start(phone: String) async throws -> WhatsAppLinkOperation {
        self.phones.append(phone)
        if self.holdStart {
            await withCheckedContinuation { continuation in self.startContinuation = continuation }
        }
        return self.starts.removeFirst()
    }

    func status(operationID: String) async throws -> WhatsAppLinkStatus {
        self.statusRequests += 1
        if self.holdStatus {
            await withCheckedContinuation { continuation in self.statusContinuation = continuation }
        }
        guard self.statuses.count > 1 else { return self.statuses[0] }
        return self.statuses.removeFirst()
    }

    func cancel(operationID: String) async throws -> WhatsAppLinkOperation {
        self.cancelled.append(operationID)
        if self.holdCancel {
            await withCheckedContinuation { continuation in self.cancelContinuation = continuation }
        }
        return self.cancellations.removeFirst()
    }

    func startedPhones() -> [String] { self.phones }
    func cancelledOperationIDs() -> [String] { self.cancelled }
    func statusRequestCount() -> Int { self.statusRequests }
    func releaseStart() { self.holdStart = false; self.startContinuation?.resume(); self.startContinuation = nil }
    func releaseStatus() { self.holdStatus = false; self.statusContinuation?.resume(); self.statusContinuation = nil }
    func releaseCancel() { self.holdCancel = false; self.cancelContinuation?.resume(); self.cancelContinuation = nil }
}
