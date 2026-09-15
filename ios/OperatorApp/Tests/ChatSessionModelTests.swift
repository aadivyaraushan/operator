import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ChatSessionModelTests: XCTestCase {
    func testWeatherCardAccessibilityIncludesActualConditions() {
        let card = WeatherCard(
            temperatureCelsius: 18.5, apparentCelsius: nil, condition: "Cloudy",
            humidity: nil, windKilometresPerHour: nil, highCelsius: nil, lowCelsius: nil,
            attribution: .init(
                legalPageURL: URL(string: "https://weather.example/legal")!,
                combinedMarkLightURL: URL(string: "https://weather.example/light")!,
                combinedMarkDarkURL: URL(string: "https://weather.example/dark")!))
        let message = ChatMessage(role: .system, text: "Weather forecast", attachment: .weather(card))
        let label = ChatMessageText.accessibilityLabel(for: message)
        XCTAssertTrue(label.contains("Cloudy"))
        XCTAssertTrue(label.contains("18.5"))
        XCTAssertTrue(label.contains("Celsius"))
    }

    func testAccessibleMessageIncludesSpeakerReadableTextAndDelivery() {
        XCTAssertEqual(
            ChatMessageText.accessibilityLabel(for: ChatMessage(role: .assistant, text: "**Hello**")),
            "Operator, Hello")
        XCTAssertEqual(
            ChatMessageText.accessibilityLabel(for: ChatMessage(role: .user, text: "Keep **literal**", delivery: .waiting)),
            "You, Keep **literal**, Waiting")
        XCTAssertEqual(
            ChatMessageText.accessibilityLabel(for: ChatMessage(role: .user, text: "Send this", delivery: .sending)),
            "You, Send this, Sending")
        XCTAssertEqual(
            ChatMessageText.accessibilityLabel(for: ChatMessage(role: .user, text: "Sent")),
            "You, Sent")
    }

    func testAssistantTextParsesMarkdownWhileUserTextStaysLiteral() throws {
        let markdown = """
        The page title is **“Example Domain.”**
        Visit [Example Domain](https://example.com)
        """

        let assistant = ChatMessage(role: .assistant, text: markdown)
        let assistantText = ChatMessageText.displayText(for: assistant)

        XCTAssertEqual(
            String(assistantText.characters),
            "The page title is “Example Domain.”\nVisit Example Domain")
        XCTAssertTrue(assistantText.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(assistantText.runs.contains {
            $0.link == URL(string: "https://example.com")
        })
        XCTAssertEqual(
            String(ChatMessageText.assistantText("First line\nSecond line").characters),
            "First line\nSecond line")

        let user = ChatMessage(role: .user, text: markdown)
        XCTAssertEqual(String(ChatMessageText.displayText(for: user).characters), markdown)
    }

    func testRestoreAndForegroundDoNotConnectBeforeRuntimeReady() async throws {
        let gateway = RuntimeGateGateway()
        let model = ChatSessionModel(store: RecordingPersistence(), gateway: gateway)
        model.runtimeIsStarting()
        model.restore()
        model.setForegroundActive(true)
        try await Task.sleep(for: .milliseconds(30))
        let beforeReady = await gateway.activationCount()
        XCTAssertEqual(beforeReady, 0)
        model.runtimeBecameReady()
        await waitUntil { model.connectionState == .ready }
        let afterReady = await gateway.activationCount()
        XCTAssertEqual(afterReady, 1)
    }

    func testSendBeforeRuntimeReadyQueuesWithoutOpeningGateway() async throws {
        let gateway = RuntimeGateGateway()
        let model = ChatSessionModel(store: RecordingPersistence(), gateway: gateway)
        model.runtimeIsStarting()
        model.restore()
        try await Task.sleep(for: .milliseconds(20))
        model.draft = "Keep queued"
        model.send()
        XCTAssertEqual(model.connectionState, .offline)
        try await Task.sleep(for: .milliseconds(30))
        let beforeReady = await gateway.deliveryCount()
        XCTAssertEqual(beforeReady, 0)
        XCTAssertEqual(model.outbox.count, 1)
        model.runtimeBecameReady()
        await waitUntil { model.messages.last?.role == .assistant }
        let afterReady = await gateway.deliveryCount()
        XCTAssertEqual(afterReady, 1)
        XCTAssertTrue(model.outbox.isEmpty)
    }

    func testBackgroundAndRuntimeFailureClearGateUntilResumeSucceeds() async throws {
        let gateway = RuntimeGateGateway()
        let model = ChatSessionModel(store: RecordingPersistence(), gateway: gateway)
        model.runtimeBecameReady()
        await waitUntil { model.connectionState == .ready }
        model.setForegroundActive(false)
        model.setForegroundActive(true)
        try await Task.sleep(for: .milliseconds(30))
        let beforeResume = await gateway.activationCount()
        XCTAssertEqual(beforeResume, 1)
        model.runtimeBecameReady()
        await waitUntil { model.connectionState == .ready }
        model.runtimeFailed("Resume failed")
        model.setForegroundActive(true)
        try await Task.sleep(for: .milliseconds(30))
        let afterFailure = await gateway.activationCount()
        XCTAssertEqual(afterFailure, 2)
        XCTAssertEqual(model.connectionState, .offline)
    }

    func testForegroundRecoveryWaitsForActiveDeliveryThenReconnectsWithoutResending() async throws {
        let gateway = HeldDeliveryGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.connectionState == .ready }
        model.draft = "Keep this request"
        model.send()
        while !(await gateway.deliveryStarted()) { await Task.yield() }
        let key = try XCTUnwrap(model.outbox.first?.idempotencyKey)

        model.setForegroundActive(false)
        model.setForegroundActive(true)
        model.runtimeBecameReady()
        try await Task.sleep(for: .milliseconds(30))
        let attemptsDuringDelivery = await gateway.activationCount()
        XCTAssertEqual(attemptsDuringDelivery, 1, "Foreground recovery must not overlap the delivery reader")

        await gateway.finishDelivery()
        await waitUntil { model.outbox.isEmpty && model.connectionState == .ready }
        try await Task.sleep(for: .milliseconds(30))
        let attemptsAfterDelivery = await gateway.activationCount()
        let keys = await gateway.deliveredKeys()
        XCTAssertEqual(attemptsAfterDelivery, 2, "Deferred foreground recovery must still run")
        XCTAssertEqual(keys, [key])
        XCTAssertEqual(model.messages.last?.text, "Finished once")
    }

    func testRestoreDoesNotClaimReadyWhenGatewayConnectionFails() async {
        let model = self.readyModel(store: RecordingPersistence(), gateway: OfflineGateway())

        model.restore()

        await waitUntil { model.connectionState != .starting }
        XCTAssertEqual(model.connectionState, .offline)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testForegroundReconnectDeliversSavedOutboxOnceWithoutReloadingDraft() async throws {
        let messageID = UUID()
        let snapshot = ConversationSnapshot(
            messages: [ChatMessage(
                id: messageID,
                role: .user,
                text: "Send after startup",
                createdAt: .now,
                delivery: .waiting)],
            draft: "Keep this draft",
            outbox: [OutboxEntry(
                id: messageID,
                messageID: messageID,
                text: "Send after startup",
                idempotencyKey: messageID.uuidString.lowercased(),
                state: .waiting)])
        let store = RecordingPersistence(snapshot: snapshot)
        let gateway = ReconnectingGateway()
        let model = self.readyModel(store: store, gateway: gateway)

        model.restore()

        await waitUntil(timeout: 2) { model.messages.last?.role == .assistant }
        XCTAssertEqual(model.draft, "Keep this draft")
        XCTAssertTrue(model.outbox.isEmpty)
        XCTAssertEqual(model.messages.map(\.text), ["Send after startup", "Delivered once"])
        let restoreCount = await store.restoreCount()
        let deliveredKeys = await gateway.deliveredKeys()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(deliveredKeys, [messageID.uuidString.lowercased()])
    }

    func testSendDuringReconnectDelayWaitsOfflineThenAutomaticallyDeliversOnce() async throws {
        let gateway = ReconnectingGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.connectionState == .offline }
        let activationAttempts = await gateway.activationAttemptCount()
        XCTAssertEqual(activationAttempts, 1)

        model.draft = "Send after retry"
        model.send()
        let key = try XCTUnwrap(model.outbox.first?.idempotencyKey)

        XCTAssertEqual(model.connectionState, .offline)
        try await Task.sleep(for: .milliseconds(30))
        let keysBeforeReconnect = await gateway.deliveredKeys()
        XCTAssertEqual(keysBeforeReconnect, [])
        XCTAssertEqual(model.outbox.first?.idempotencyKey, key)

        await waitUntil(timeout: 2) { model.messages.last?.role == .assistant }
        let keysAfterReconnect = await gateway.deliveredKeys()
        XCTAssertEqual(keysAfterReconnect, [key])
        XCTAssertTrue(model.outbox.isEmpty)
    }

    func testDeliveryFailureClearsReadinessUntilBlockedReconnectCompletes() async throws {
        let gateway = DeliveryFailureReconnectGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.connectionState == .ready }

        model.draft = "First request"
        model.send()
        let firstKey = try XCTUnwrap(model.outbox.first?.idempotencyKey)
        while !(await gateway.reconnectHasStarted()) { await Task.yield() }
        XCTAssertEqual(model.connectionState, .offline)

        model.draft = "Second request"
        model.send()
        let secondKey = try XCTUnwrap(model.outbox.last?.idempotencyKey)
        XCTAssertEqual(model.connectionState, .offline)
        let attemptsBeforeReconnect = await gateway.deliveryAttemptCount()
        XCTAssertEqual(attemptsBeforeReconnect, 1)

        await gateway.finishReconnect()
        await waitUntil(timeout: 1) { model.outbox.isEmpty }
        let successfulKeys = await gateway.successfulKeys()
        let totalAttempts = await gateway.deliveryAttemptCount()
        XCTAssertEqual(successfulKeys, [firstKey, secondKey])
        XCTAssertEqual(totalAttempts, 3)
    }

    func testBackgroundRestoreDoesNotStartReconnects() async throws {
        let gateway = ReconnectingGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)

        model.setForegroundActive(false)
        model.restore()

        try await Task.sleep(nanoseconds: 100_000_000)
        let activationAttempts = await gateway.activationAttemptCount()
        XCTAssertEqual(activationAttempts, 0)
    }

    func testForegroundReturnAfterCancelledSubscriptionReconnectsThenFlushesOnce() async throws {
        let gateway = SuspendedReconnectGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)

        model.restore()
        while !(await gateway.firstActivationHasStarted()) {
            await Task.yield()
        }
        model.draft = "Send after reconnect"
        model.send()
        await waitUntil { model.outbox.count == 1 }
        let deliveryCountBeforeReturn = await gateway.deliveryCount()
        XCTAssertEqual(deliveryCountBeforeReturn, 0)

        model.setForegroundActive(false)
        model.setForegroundActive(true)
        await gateway.finishFirstActivation()
        model.runtimeBecameReady()

        await waitUntil(timeout: 1) { model.messages.last?.role == .assistant }
        let activationAttempts = await gateway.activationAttemptCount()
        let deliveryCount = await gateway.deliveryCount()
        XCTAssertEqual(activationAttempts, 2)
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertTrue(model.outbox.isEmpty)
    }

    func testForegroundNodeStartsOnlyAfterChatGatewayIsReady() async {
        let chat = ControlledChatReadiness()
        let node = RecordingForegroundNode()
        let coordinator = ForegroundRuntimeCoordinator(
            waitForChatGateway: { await chat.waitUntilReady() },
            startNode: { await node.start() },
            stopNode: { await node.stop() })

        coordinator.setForegroundActive(true)
        while !(await chat.hasStartedWaiting()) {
            await Task.yield()
        }
        let startsBeforeChatReady = await node.startCount()
        XCTAssertEqual(startsBeforeChatReady, 0)

        await chat.markReady()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let startsAfterChatReady = await node.startCount()
        XCTAssertEqual(startsAfterChatReady, 1)
    }

    func testBackgroundBeforeChatReadyDoesNotStartForegroundNode() async {
        let chat = ControlledChatReadiness()
        let node = RecordingForegroundNode()
        let coordinator = ForegroundRuntimeCoordinator(
            waitForChatGateway: { await chat.waitUntilReady() },
            startNode: { await node.start() },
            stopNode: { await node.stop() })

        coordinator.setForegroundActive(true)
        while !(await chat.hasStartedWaiting()) {
            await Task.yield()
        }
        coordinator.setForegroundActive(false)
        await chat.markReady()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let starts = await node.startCount()
        let stops = await node.stopCount()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 1)
    }

    func testRestoreAndWaitForGatewayReadyWaitsForApprovalSubscription() async {
        let gateway = SubscriptionGateGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        let waiting = Task { @MainActor in
            await model.restoreAndWaitForGatewayReady()
        }

        while !(await gateway.firstSubscriptionHasStarted()) {
            await Task.yield()
        }
        XCTAssertFalse(waiting.isCancelled)

        await gateway.finishFirstSubscription()
        let didBecomeReady = await waiting.value
        XCTAssertTrue(didBecomeReady)
    }

    func testBackgroundReleasesGatewayWaitAndForegroundCanReconnect() async {
        let gateway = SubscriptionGateGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        let initialWait = Task { @MainActor in
            await model.restoreAndWaitForGatewayReady()
        }

        while !(await gateway.firstSubscriptionHasStarted()) {
            await Task.yield()
        }
        model.setForegroundActive(false)
        let didReleaseInBackground = await initialWait.value
        XCTAssertFalse(didReleaseInBackground)

        model.setForegroundActive(true)
        let foregroundWait = Task { @MainActor in
            await model.restoreAndWaitForGatewayReady()
        }
        await gateway.finishFirstSubscription()
        model.runtimeBecameReady()

        let didReconnect = await foregroundWait.value
        let subscriptionAttempts = await gateway.subscriptionAttemptCount()
        XCTAssertTrue(didReconnect)
        XCTAssertEqual(subscriptionAttempts, 2)
    }

    func testSendAppearsImmediatelyAndKeepsStableOutboxIdentity() async throws {
        let store = RecordingPersistence()
        let model = self.readyModel(store: store, gateway: SuspendedGateway())
        model.restore()
        await waitUntil { model.connectionState == .ready }
        model.draft = "Summarize the project status"

        model.send()

        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.messages.map(\.text), ["Summarize the project status"])
        XCTAssertEqual(model.outbox.count, 1)
        XCTAssertEqual(model.outbox.first?.messageID, model.messages.first?.id)
        XCTAssertEqual(
            model.outbox.first?.idempotencyKey,
            model.messages.first?.id.uuidString.lowercased())
        XCTAssertEqual(model.connectionState, .working)
    }

    func testOfflineGatewayKeepsDurableMessageQueuedWithoutInventingReply() async throws {
        let store = RecordingPersistence()
        let model = self.readyModel(store: store, gateway: OfflineGateway())
        model.draft = "Check the build"

        model.send()

        await waitUntil { model.connectionState == .offline }
        XCTAssertEqual(model.outbox.map(\.text), ["Check the build"])
        XCTAssertEqual(model.messages.map(\.role), [.user])
        XCTAssertNil(model.streamingReply)
    }

    func testGatewayUpdatesStreamThenPersistOneFinalAssistantReply() async throws {
        let store = RecordingPersistence()
        let model = self.readyModel(store: store, gateway: ReplyingGateway())
        model.draft = "Hello"

        model.send()

        await waitUntil { model.messages.last?.role == .assistant }
        XCTAssertEqual(model.messages.map(\.text), ["Hello", "Hi there"])
        XCTAssertTrue(model.outbox.isEmpty)
        XCTAssertNil(model.streamingReply)
        XCTAssertEqual(model.connectionState, .ready)
    }

    func testServerApprovalReplayRendersOnlyPendingItemThenUsesCanonicalTerminalSnapshot() async throws {
        let pending = try approvalSnapshot(status: "pending")
        let resolved = try approvalSnapshot(status: "denied", decision: "deny")
        let gateway = ApprovingGateway(pending: pending, resolved: resolved)
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)

        model.restore()
        await waitUntil { model.approvals.map(\.id) == ["approval-exact-1"] }
        model.resolveApproval(id: pending.id, decision: .deny)
        await waitUntil { model.approvals.isEmpty }

        let resolvedID = await gateway.resolvedID()
        let resolvedDecision = await gateway.resolvedDecision()
        XCTAssertEqual(resolvedID, "approval-exact-1")
        XCTAssertEqual(resolvedDecision, .deny)
        XCTAssertNil(model.lastError)
    }

    private func readyModel(store: any ChatPersistence, gateway: any ChatGateway) -> ChatSessionModel {
        let model = ChatSessionModel(store: store, gateway: gateway)
        model.runtimeBecameReady()
        return model
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            await Task.yield()
        }
    }

    private func approvalSnapshot(status: String, decision: String? = nil) throws -> GatewayApprovalSnapshot {
        let terminal = decision.map {
            ",\"decision\":\"\($0)\",\"resolvedAtMs\":1725000000200,\"reason\":\"user\""
        } ?? ""
        let json = """
        {"id":"approval-exact-1","createdAtMs":1725000000000,"expiresAtMs":2725003600000,"status":"\(status)"\(terminal),"presentation":{"kind":"exec","commandText":"git status","allowedDecisions":["allow-once","deny"]}}
        """
        let data = Data(json.utf8)
        return try JSONDecoder().decode(GatewayApprovalSnapshot.self, from: data)
    }
}

private actor RecordingPersistence: ChatPersistence {
    private var snapshot: ConversationSnapshot
    private var restores = 0

    init(snapshot: ConversationSnapshot = ConversationSnapshot()) {
        self.snapshot = snapshot
    }

    func restore() async throws -> ConversationSnapshot {
        self.restores += 1
        return self.snapshot
    }

    func restoreCount() -> Int { self.restores }

    func saveDraft(_ draft: String) async throws -> ConversationSnapshot {
        self.snapshot.draft = draft
        return self.snapshot
    }

    func stage(id: UUID, text: String, now: Date) async throws -> ConversationSnapshot {
        self.snapshot.messages.append(ChatMessage(
            id: id,
            role: .user,
            text: text,
            createdAt: now,
            delivery: .waiting))
        self.snapshot.outbox.append(OutboxEntry(
            id: id,
            messageID: id,
            text: text,
            idempotencyKey: id.uuidString.lowercased(),
            state: .waiting))
        self.snapshot.draft = ""
        return self.snapshot
    }

    func markSending(id: UUID) async throws -> ConversationSnapshot {
        self.snapshot.outbox[0].state = .sending
        self.snapshot.messages[0].delivery = .sending
        return self.snapshot
    }

    func markAccepted(id: UUID) async throws -> ConversationSnapshot {
        self.snapshot.outbox.removeAll { $0.id == id }
        self.snapshot.messages[0].delivery = .accepted
        return self.snapshot
    }

    func markWaiting(id: UUID) async throws -> ConversationSnapshot {
        self.snapshot.outbox[0].state = .waiting
        self.snapshot.messages[0].delivery = .waiting
        return self.snapshot
    }

    func appendAssistant(_ text: String) async throws -> ConversationSnapshot {
        self.snapshot.messages.append(ChatMessage(role: .assistant, text: text))
        return self.snapshot
    }

    func appendWeatherCard(_ card: WeatherCard) async throws -> ConversationSnapshot {
        self.snapshot.messages.append(ChatMessage(role: .system, text: "Weather forecast", attachment: .weather(card)))
        return self.snapshot
    }
}

private actor SuspendedGateway: ChatGateway {
    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
}

private actor HeldDeliveryGateway: ChatGateway {
    private var activations = 0
    private var keys: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func activateApprovalUpdates(_ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws {
        activations += 1
    }
    func deliver(_ entry: OutboxEntry, update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws {
        keys.append(entry.idempotencyKey)
        await withCheckedContinuation { continuation = $0 }
        await update(.reply("Finished once"))
    }
    func deliveryStarted() -> Bool { continuation != nil }
    func finishDelivery() { continuation?.resume(); continuation = nil }
    func activationCount() -> Int { activations }
    func deliveredKeys() -> [String] { keys }
}

private actor RuntimeGateGateway: ChatGateway {
    private var activations = 0
    private var deliveries = 0
    func activateApprovalUpdates(_ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws { activations += 1 }
    func deliver(_ entry: OutboxEntry, update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws {
        deliveries += 1
        await update(.reply("Delivered after runtime ready"))
    }
    func activationCount() -> Int { activations }
    func deliveryCount() -> Int { deliveries }
}

private struct OfflineGateway: ChatGateway {
    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    {
        throw ChatGatewayError.offline
    }

    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        throw ChatGatewayError.offline
    }
}

private struct ReplyingGateway: ChatGateway {
    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        await update(.accepted)
        await update(.working)
        await update(.stream("Hi"))
        await update(.reply("Hi there"))
    }
}

private actor ReconnectingGateway: ChatGateway {
    private var activationAttempts = 0
    private var keys: [String] = []

    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    {
        self.activationAttempts += 1
        if self.activationAttempts == 1 {
            throw ChatGatewayError.offline
        }
    }

    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        self.keys.append(entry.idempotencyKey)
        await update(.accepted)
        await update(.reply("Delivered once"))
    }

    func deliveredKeys() -> [String] { self.keys }
    func activationAttemptCount() -> Int { self.activationAttempts }
}

private actor DeliveryFailureReconnectGateway: ChatGateway {
    private var activationAttempts = 0
    private var deliveryAttempts = 0
    private var deliveredKeys: [String] = []
    private var reconnectContinuation: CheckedContinuation<Void, Never>?

    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    {
        self.activationAttempts += 1
        if self.activationAttempts == 2 {
            await withCheckedContinuation { self.reconnectContinuation = $0 }
        }
    }

    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        self.deliveryAttempts += 1
        if self.deliveryAttempts == 1 {
            throw ChatGatewayError.offline
        }
        self.deliveredKeys.append(entry.idempotencyKey)
        await update(.accepted)
        await update(.reply("Delivered after reconnect"))
    }

    func reconnectHasStarted() -> Bool { self.reconnectContinuation != nil }
    func finishReconnect() {
        self.reconnectContinuation?.resume()
        self.reconnectContinuation = nil
    }
    func deliveryAttemptCount() -> Int { self.deliveryAttempts }
    func successfulKeys() -> [String] { self.deliveredKeys }
}

private actor SuspendedReconnectGateway: ChatGateway {
    private var activationAttempts = 0
    private var firstActivationStarted = false
    private var firstActivationContinuation: CheckedContinuation<Void, Never>?
    private var deliveries = 0

    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    {
        self.activationAttempts += 1
        if self.activationAttempts == 1 {
            self.firstActivationStarted = true
            await withCheckedContinuation { continuation in
                self.firstActivationContinuation = continuation
            }
        }
    }

    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        self.deliveries += 1
        await update(.accepted)
        await update(.reply("Delivered after reconnect"))
    }

    func firstActivationHasStarted() -> Bool { self.firstActivationStarted }
    func finishFirstActivation() {
        self.firstActivationContinuation?.resume()
        self.firstActivationContinuation = nil
    }
    func activationAttemptCount() -> Int { self.activationAttempts }
    func deliveryCount() -> Int { self.deliveries }
}

private actor ControlledChatReadiness {
    private var waiting = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func waitUntilReady() async -> Bool {
        self.waiting = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStartedWaiting() -> Bool { self.waiting }
    func markReady() {
        self.continuation?.resume(returning: true)
        self.continuation = nil
    }
}

private actor SubscriptionGateGateway: ChatGateway {
    private var subscriptionAttempts = 0
    private var firstSubscriptionStarted = false
    private var firstSubscriptionContinuation: CheckedContinuation<Void, Never>?

    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    {
        self.subscriptionAttempts += 1
        if self.subscriptionAttempts == 1 {
            self.firstSubscriptionStarted = true
            await withCheckedContinuation { continuation in
                self.firstSubscriptionContinuation = continuation
            }
        }
    }

    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        XCTFail("A provider reply is not needed to establish chat gateway readiness")
    }

    func firstSubscriptionHasStarted() -> Bool { self.firstSubscriptionStarted }
    func finishFirstSubscription() {
        self.firstSubscriptionContinuation?.resume()
        self.firstSubscriptionContinuation = nil
    }
    func subscriptionAttemptCount() -> Int { self.subscriptionAttempts }
}

private actor RecordingForegroundNode {
    private var starts = 0
    private var stops = 0

    func start() { self.starts += 1 }
    func stop() { self.stops += 1 }
    func startCount() -> Int { self.starts }
    func stopCount() -> Int { self.stops }
}

private actor ApprovingGateway: ChatGateway {
    private let pending: GatewayApprovalSnapshot
    private let resolved: GatewayApprovalSnapshot
    private var id: String?
    private var decision: GatewayApprovalDecision?

    init(pending: GatewayApprovalSnapshot, resolved: GatewayApprovalSnapshot) {
        self.pending = pending
        self.resolved = resolved
    }

    func deliver(
        _ entry: OutboxEntry,
        update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws
    {
        await update(.accepted)
    }

    func activateApprovalUpdates(
        _ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws
    {
        await update(.replay(.init(
            sessionKey: "agent:main:main",
            updatedAtMilliseconds: 1,
            approvals: [self.pending],
            truncated: false)))
    }

    func resolveApproval(
        id: String,
        kind: GatewayApprovalKind,
        decision: GatewayApprovalDecision) async throws -> GatewayApprovalSnapshot
    {
        self.id = id
        self.decision = decision
        return self.resolved
    }

    func resolvedID() -> String? { self.id }
    func resolvedDecision() -> GatewayApprovalDecision? { self.decision }
}
