import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ChatSessionModelTests: XCTestCase {
    func testConversationReviewWaitsForReadinessAndNeverOverwritesDraft() async {
        let model = ChatSessionModel(store: RecordingPersistence(), gateway: RuntimeGateGateway())
        XCTAssertFalse(model.canReviewConversationTasks)
        await model.reviewConversationTask(id: "task")
        XCTAssertTrue(model.messages.isEmpty)
        model.runtimeBecameReady()
        await waitUntil { model.connectionState == .ready }
        XCTAssertTrue(model.canReviewConversationTasks)
        model.draft = "My unfinished question"
        await model.reviewConversationTask(id: "task")
        XCTAssertEqual(model.draft, "My unfinished question")
        XCTAssertTrue(model.messages.isEmpty)
        model.draft = ""
        await model.reviewConversationTask(id: "task")
        XCTAssertTrue(model.messages.contains { $0.text.contains("Operator conversation task review: task") })
        model.runtimeDidSuspend()
        XCTAssertFalse(model.canReviewConversationTasks)
    }

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
        XCTAssertEqual(
            ChatMessageText.accessibilityLabel(for: ChatMessage(role: .user, text: "Taken", delivery: .sending), inFlight: true),
            "You, Taken", "once the runtime has the message there is nothing to say under it")
        XCTAssertNil(ChatMessageText.deliveryLabel(for: ChatMessage(role: .user, text: "Taken", delivery: .sending), inFlight: true))
        XCTAssertEqual(ChatMessageText.deliveryLabel(for: ChatMessage(role: .user, text: "Queued", delivery: .waiting), inFlight: false), "Waiting")
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

    func testLiveActivityShowsEachStepFromAcceptanceAndStaysWithTheReply() async throws {
        let gateway = ActivityGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.connectionState == .ready }
        model.draft = "what did I miss on discord?"
        model.send()

        XCTAssertEqual(model.liveActivity, ChatLiveActivity(), "the dots are up the moment the message is sent")
        await gateway.waitForStage(1)
        XCTAssertEqual(model.liveActivity, ChatLiveActivity(), "accepted: still thinking, no steps yet")
        let sent = try XCTUnwrap(model.messages.first { $0.role == .user })
        XCTAssertEqual(sent.delivery, .sending, "the store keeps it in the outbox until the reply")
        XCTAssertTrue(model.inFlight.contains(sent.id), "but the bubble no longer says Sending")

        await gateway.proceed()
        await gateway.waitForStage(2)
        let running = try XCTUnwrap(model.liveActivity)
        XCTAssertEqual(running.reasoning, "The person wants a digest.")
        XCTAssertEqual(running.commentary, ["I'll read the announcement channels first."])
        XCTAssertEqual(running.steps.map(\.title), ["Checking Discord announcements"])
        XCTAssertEqual(running.steps.map(\.call), [#"discord_announcements(limit: 25)"#], "the exact call stays behind the words")
        XCTAssertEqual(running.steps.first?.state, .running)

        await gateway.proceed()
        await gateway.waitForStage(3)
        let afterTools = try XCTUnwrap(model.liveActivity)
        XCTAssertEqual(afterTools.steps.map(\.title), ["Checked Discord announcements", "Read Gmail"], "past tense once done; the node bridge is unwrapped to the command it carried")
        XCTAssertEqual(afterTools.steps.map(\.call), [#"discord_announcements(limit: 25)"#, #"connections.read(operation: "gmailMessages", limit: 5)"#])
        XCTAssertEqual(afterTools.steps.map(\.state), [.done, .failed])
        XCTAssertEqual(afterTools.phase, .thinking, "between tools the agent is thinking again")

        await gateway.proceed()
        await gateway.waitForStage(4)
        XCTAssertEqual(model.liveActivity?.phase, .writing)
        XCTAssertEqual(model.streamingReply, "Here")

        await gateway.proceed()
        await waitUntil { model.liveActivity == nil && model.messages.last?.role == .assistant }
        let reply = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(reply.text, "Here is the digest")
        XCTAssertEqual(model.stepsByReply[reply.id]?.map(\.name), ["discord_announcements", "connections.read"], "the steps stay under the reply they produced")
        XCTAssertNil(model.streamingReply)
        XCTAssertTrue(model.inFlight.isEmpty)
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

    /// Operator opened Settings mid-reply; the frozen send never returned, the
    /// reconnect refused to start while it was "in progress", and every later
    /// message sat on Waiting for good.
    func testLeavingTheAppMidReplyReleasesTheSendSoTheQueueResumesOnReturn() async throws {
        let gateway = FrozenUntilLetGoGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        model.draft = "open the settings app"
        model.send()
        while !(await gateway.deliveryCount() == 1) { await Task.yield() }

        model.runtimeDidSuspend()
        while !(await gateway.letGoCount() == 1) { await Task.yield() }
        model.draft = "open gmail"
        model.send()

        model.runtimeIsStarting()
        model.setForegroundActive(true)
        model.runtimeBecameReady()

        await waitUntil(timeout: 2) { model.messages.filter { $0.role == .assistant }.count == 2 }
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.map(\.text), ["Reply 2", "Reply 3"])
        XCTAssertTrue(model.outbox.isEmpty)
    }

    func testAMessageSentWhileAReplyIsRunningJoinsThatRunInsteadOfWaitingBehindIt() async throws {
        let gateway = JoiningGateway()
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        model.draft = "plan my day"
        model.send()
        while !(await gateway.deliveryStarted()) { await Task.yield() }

        model.draft = "also include the gym"
        model.send()
        while !(await gateway.joinedTexts() == ["also include the gym"]) { await Task.yield() }
        XCTAssertEqual(model.connectionState, .working)

        await gateway.finishDelivery()
        await waitUntil(timeout: 2) { model.outbox.isEmpty }
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.map(\.text), ["One reply covering both"])
        XCTAssertNil(model.lastError)
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

    func testAQuestionReplayedOnConnectIsShownAnsweredAndCollapsed() async throws {
        let record = try questionRecord(id: "ask_1")
        let gateway = QuestioningGateway(replay: [record])
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)

        model.restore()
        await waitUntil { model.questions.map(\.id) == ["ask_1"] }
        XCTAssertEqual(model.questions.first?.questions.first?.options.map(\.label), ["MVP update", "Call now", "Meet tomorrow"])

        model.answerQuestion(id: "ask_1", answers: ["group_message": ["Call now"]])
        await waitUntil { model.questions.isEmpty }

        let answered = await gateway.answered()
        XCTAssertEqual(answered.map(\.id), ["ask_1"])
        XCTAssertEqual(answered.first?.answers.answers, ["group_message": ["Call now"]])
        XCTAssertEqual(model.answeredQuestions.map(\.chosen), [["Call now"]])
        XCTAssertEqual(model.answeredQuestions.first?.prompts, ["What should I send in the group chat?"])
        XCTAssertNil(model.lastError)
    }

    func testAQuestionRequestedDuringARunIsShownAndAResolvedEventFromElsewhereRemovesIt() async throws {
        let record = try questionRecord(id: "ask_2")
        let gateway = QuestioningGateway(replay: [], duringRun: record)
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.connectionState == .ready }
        model.draft = "message them"
        model.send()

        await waitUntil { model.questions.map(\.id) == ["ask_2"] }
        await gateway.resolveFromElsewhere(id: "ask_2", answers: ["group_message": ["Meet tomorrow"]])
        await waitUntil { model.questions.isEmpty }

        XCTAssertEqual(model.answeredQuestions.map(\.chosen), [["Meet tomorrow"]])
        let answered = await gateway.answered()
        XCTAssertTrue(answered.isEmpty, "the phone did not answer; someone else did")
    }

    func testAnAnswerThatDoesNotFitTheQuestionIsRefusedLocally() async throws {
        let record = try questionRecord(id: "ask_3")
        let gateway = QuestioningGateway(replay: [record])
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.questions.map(\.id) == ["ask_3"] }

        model.answerQuestion(id: "ask_3", answers: ["group_message": ["Something the model never offered"]])
        await waitUntil { model.lastError != nil }
        model.answerQuestion(id: "ask_3", answers: ["group_message": ["Call now", "Meet tomorrow"]])
        model.answerQuestion(id: "ask_3", answers: [:])

        let answered = await gateway.answered()
        XCTAssertTrue(answered.isEmpty)
        XCTAssertEqual(model.questions.map(\.id), ["ask_3"], "the card stays until a fitting answer")
    }

    func testAFreeTextQuestionTakesAnyNonEmptyAnswerAndSkipCancels() async throws {
        let free = try questionRecord(id: "ask_4", options: false)
        let other = try questionRecord(id: "ask_5")
        let gateway = QuestioningGateway(replay: [free, other])
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.questions.count == 2 }

        model.answerQuestion(id: "ask_4", answers: ["group_message": ["tell them I'm running late"]])
        model.skipQuestion(id: "ask_5")
        await waitUntil { model.questions.isEmpty }

        let answered = await gateway.answered()
        let cancelled = await gateway.cancelled()
        XCTAssertEqual(answered.first?.answers.answers, ["group_message": ["tell them I'm running late"]])
        XCTAssertEqual(cancelled, ["ask_5"])
    }

    func testAQuestionAskedWhileTheAppIsNotInFrontReachesTheNotifierAndIsWithdrawnWhenSettled() async throws {
        let record = try questionRecord(id: "ask_8")
        let gateway = QuestioningGateway(replay: [], duringRun: record)
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        var notified: [String] = []
        var withdrawn: [String] = []
        model.isInForeground = { false }
        model.onQuestionInBackground = { notified.append($0.id) }
        model.onQuestionSettled = { withdrawn.append($0) }
        model.restore()
        await waitUntil { model.connectionState == .ready }
        model.draft = "message them"
        model.send()

        await waitUntil { model.questions.map(\.id) == ["ask_8"] }
        XCTAssertEqual(notified, ["ask_8"])
        let sent = await model.answerQuestionAndWait(id: "ask_8", answers: ["group_message": ["Call now"]])
        XCTAssertTrue(sent)
        XCTAssertEqual(withdrawn, ["ask_8"])
        XCTAssertTrue(model.questions.isEmpty)
    }

    func testAQuestionAskedWhileTheAppIsInFrontIsNotNotified() async throws {
        let record = try questionRecord(id: "ask_9")
        let gateway = QuestioningGateway(replay: [], duringRun: record)
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        var notified: [String] = []
        model.onQuestionInBackground = { notified.append($0.id) }
        model.restore()
        await waitUntil { model.connectionState == .ready }
        model.draft = "message them"
        model.send()

        await waitUntil { model.questions.map(\.id) == ["ask_9"] }
        XCTAssertTrue(notified.isEmpty)
        await gateway.resolveFromElsewhere(id: "ask_9", answers: ["group_message": ["Call now"]])
        await waitUntil { model.questions.isEmpty }
    }

    func testASecretQuestionIsCancelledAtOnceAndNeverShown() async throws {
        let secret = try questionRecord(id: "ask_6", secret: true)
        let gateway = QuestioningGateway(replay: [secret])
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.connectionState == .ready }
        var cancelled = await gateway.cancelled()
        let end = Date().addingTimeInterval(1)
        while cancelled.isEmpty, Date() < end {
            await Task.yield()
            cancelled = await gateway.cancelled()
        }
        XCTAssertEqual(cancelled, ["ask_6"])
        XCTAssertTrue(model.questions.isEmpty)
    }

    func testAnExpiredQuestionInTheReplayIsNotShown() async throws {
        let expired = try questionRecord(id: "ask_7", expiresAtMs: 1725000001000)
        let gateway = QuestioningGateway(replay: [expired])
        let model = self.readyModel(store: RecordingPersistence(), gateway: gateway)
        model.restore()
        await waitUntil { model.connectionState == .ready }
        XCTAssertTrue(model.questions.isEmpty)
    }

    func testAReplyInFlightIsKeptAliveByAContinuationAndReachesThePersonWhoLeft() async throws {
        final class Scheduler: ContinuedProcessingScheduling {
            var handler: (@MainActor (any ContinuedProcessingTask) -> Void)?
            var submitted: [String] = []
            func submit(identifier: String, title: String, subtitle: String, handler: @escaping @MainActor (any ContinuedProcessingTask) -> Void) throws {
                self.handler = handler
                self.submitted.append(identifier)
            }
        }
        final class Task_: ContinuedProcessingTask, @unchecked Sendable {
            let identifier: String
            var expirationHandler: (@Sendable () -> Void)?
            var progress: [Int] = []
            var subtitles: [String] = []
            var completed: [Bool] = []
            init(identifier: String) { self.identifier = identifier }
            func setProgress(completed: Int, total: Int) { self.progress.append(completed) }
            func updateTitle(_ title: String, subtitle: String) { self.subtitles.append(subtitle) }
            func setTaskCompleted(success: Bool) { self.completed.append(success) }
        }
        let scheduler = Scheduler()
        let continuation = ReplyContinuation(scheduler: scheduler, heartbeatInterval: .seconds(60))
        let gateway = ActivityGateway()
        let model = ChatSessionModel(store: RecordingPersistence(), gateway: gateway, continuation: continuation)
        var inForeground = true
        var notified: [String] = []
        model.isInForeground = { inForeground }
        model.onReplyInBackground = { notified.append($0) }
        model.runtimeBecameReady()
        model.restore()
        await waitUntil { model.connectionState == .ready }

        model.draft = "what did I miss on discord?"
        model.send()
        await waitUntil { continuation.isActive }
        XCTAssertTrue(continuation.isActive, "the task is submitted as the delivery starts")
        XCTAssertEqual(scheduler.submitted.count, 1)
        let task = Task_(identifier: scheduler.submitted[0])
        scheduler.handler?(task)

        await gateway.waitForStage(1)
        await gateway.proceed()
        await gateway.waitForStage(2)
        XCTAssertEqual(scheduler.submitted.count, 1)
        inForeground = false // the person leaves while the tools run
        await gateway.proceed()
        await gateway.waitForStage(3)
        await gateway.proceed()
        await gateway.waitForStage(4)
        XCTAssertEqual(task.subtitles, [], "no title updates after submission")
        XCTAssertEqual(task.progress, [1], "the system started the task before anything was reported, so the first tick delivered one step; the heartbeat is a minute away in this test")
        XCTAssertEqual(continuation.lastProgress, 80, "tracked for the heartbeat")
        await gateway.proceed()
        await waitUntil { !continuation.isActive }
        XCTAssertEqual(task.completed, [true])
        XCTAssertEqual(task.progress.last, 100)
        XCTAssertEqual(notified, ["Here is the digest"], "the reply reaches the person who left")
        XCTAssertEqual(model.messages.last?.text, "Here is the digest")
    }

    func testStepsSpeakPlainlyAndKeepTheExactBoundedCallBehindThem() {
        let plain = ChatActivityStep(id: "1", tool: "web_search", arguments: ["query": .string("discord self-bot ban 2026"), "count": .number(5)], state: .running)
        XCTAssertEqual(plain.title, "Searching the web")
        XCTAssertEqual(plain.call, #"web_search(query: "discord self-bot ban 2026", count: 5)"#)

        let bridged = ChatActivityStep(id: "2", tool: "nodes", arguments: [
            "action": .string("invoke"), "node": .string("iphone"), "invokeCommand": .string("whatsapp.compose"),
            "invokeParamsJson": .string(#"{"recipient":"+1 555 0100","body":"running late, there in 10\nsorry"}"#), "invokeTimeoutMs": .number(30_000),
        ], state: .done)
        XCTAssertEqual(bridged.name, "whatsapp.compose")
        XCTAssertEqual(bridged.title, "Prepared a WhatsApp message")
        XCTAssertEqual(bridged.call, #"whatsapp.compose(recipient: "+1 555 0100", body: "running late, there in 10 sorry")"#)

        let bare = ChatActivityStep(id: "3", tool: "nodes", arguments: ["action": .string("status")], state: .done)
        XCTAssertEqual(bare.call, "nodes()", "a bridge call with no command keeps its own name and hides the bookkeeping")
        XCTAssertEqual(bare.title, "Checked this iPhone's tools")

        let unknown = ChatActivityStep(id: "5", tool: "some_new.tool", arguments: [:], state: .running)
        XCTAssertEqual(unknown.title, "Using some new tool", "a tool the words do not cover is still named")
        let mail = ChatActivityStep(id: "6", tool: "nodes", arguments: [
            "action": .string("invoke"), "invokeCommand": .string("connections.write"), "invokeParamsJson": .string(#"{"operation":"outlookSendMail"}"#),
        ], state: .running)
        XCTAssertEqual(mail.title, "Writing to Outlook")

        let long = ChatActivityStep(id: "4", tool: "exec", arguments: [
            "command": .string(String(repeating: "x", count: 200)), "host": .string("node"), "cwd": .string("/"), "env": .object(["A": .string("1")]), "z": .bool(true),
        ], state: .failed)
        XCTAssertTrue(long.arguments.hasPrefix(#"command: ""# + String(repeating: "x", count: ChatActivityFormatter.valueLimit - 1) + "…\""), long.arguments)
        XCTAssertTrue(long.arguments.hasSuffix(", …"), "more than three arguments is said, not shown")
        XCTAssertLessThanOrEqual(long.arguments.count, ChatActivityFormatter.lineLimit)
        XCTAssertEqual(ChatActivityFormatter.summary(["items": .array([.null, .null]), "flag": .bool(false)]), "flag: false, items: [2 items]")
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

    private func questionRecord(id: String, options: Bool = true, secret: Bool = false, expiresAtMs: Int = 2725003600000) throws -> GatewayQuestionRecord {
        let optionList = options
            ? #"[{"label":"MVP update","description":"Coordinate Spotify testing."},{"label":"Call now"},{"label":"Meet tomorrow"}]"#
            : "[]"
        let json = """
        {"id":"\(id)","questions":[{"questionId":"group_message","header":"Message","question":"What should I send in the group chat?","options":\(optionList),"isSecret":\(secret)}],"sessionKey":"agent:main:main","runId":"run-1","createdAtMs":1725000000000,"expiresAtMs":\(expiresAtMs),"status":"pending"}
        """
        return try JSONDecoder().decode(GatewayQuestionRecord.self, from: Data(json.utf8))
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

actor RecordingPersistence: ChatPersistence {
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

actor RuntimeGateGateway: ChatGateway {
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

/// Delivers in stages the test releases one at a time, so each intermediate
/// state of the model can be checked while the delivery is still open.
private actor ActivityGateway: ChatGateway {
    private var stage = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var stageWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func deliver(_ entry: OutboxEntry, update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws {
        await update(.accepted)
        await self.reach(1)
        await update(.activity(.thinking(text: "The person wants a digest.")))
        await update(.activity(.commentary(text: "I'll read the announcement channels first.")))
        await update(.activity(.toolStarted(tool: "discord_announcements", callID: "c1", arguments: ["limit": .number(25)])))
        await self.reach(2)
        await update(.activity(.toolFinished(tool: "discord_announcements", callID: "c1", isError: false)))
        await update(.activity(.toolStarted(tool: "nodes", callID: "c2", arguments: [
            "action": .string("invoke"), "node": .string("iphone"), "invokeCommand": .string("connections.read"),
            "invokeParamsJson": .string(#"{"operation":"gmailMessages","limit":5}"#), "invokeTimeoutMs": .number(30_000),
        ])))
        await update(.activity(.toolFinished(tool: "nodes", callID: "c2", isError: true)))
        await self.reach(3)
        await update(.stream("Here"))
        await self.reach(4)
        await update(.reply("Here is the digest"))
    }

    private func reach(_ stage: Int) async {
        self.stage = stage
        for (wanted, waiter) in self.stageWaiters where wanted <= stage { waiter.resume() }
        self.stageWaiters.removeAll { $0.0 <= stage }
        await withCheckedContinuation { self.gate = $0 }
    }

    func waitForStage(_ wanted: Int) async {
        if self.stage >= wanted { return }
        await withCheckedContinuation { self.stageWaiters.append((wanted, $0)) }
        // Let the model apply the update that preceded the stage marker.
        await Task.yield()
    }

    func proceed() {
        self.gate?.resume()
        self.gate = nil
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

/// A gateway holding questions: some replayed on connect, one raised while a
/// message is delivered. Answers and cancels are recorded, not acted on;
/// `resolveFromElsewhere` plays the event another client's answer would cause.
private actor QuestioningGateway: ChatGateway {
    struct Answer: Equatable { let id: String; let answers: GatewayQuestionAnswers }
    private let replay: [GatewayQuestionRecord]
    private let duringRun: GatewayQuestionRecord?
    private var questionUpdate: (@Sendable (ChatQuestionUpdate) async -> Void)?
    private var answers: [Answer] = []
    private var cancels: [String] = []

    init(replay: [GatewayQuestionRecord], duringRun: GatewayQuestionRecord? = nil) {
        self.replay = replay
        self.duringRun = duringRun
    }

    func activateApprovalUpdates(_ update: @escaping @Sendable (ChatApprovalUpdate) async -> Void) async throws {}

    func activateQuestionUpdates(_ update: @escaping @Sendable (ChatQuestionUpdate) async -> Void) async throws {
        self.questionUpdate = update
        await update(.replay(self.replay))
    }

    func deliver(_ entry: OutboxEntry, update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws {
        await update(.accepted)
        if let duringRun { await self.questionUpdate?(.requested(duringRun)) }
        // The run stays open until the question is settled, as the real one would.
        while self.answers.isEmpty, self.cancels.isEmpty, !Task.isCancelled, self.duringRun != nil, !self.resolvedElsewhere {
            await Task.yield()
        }
        await update(.reply("Done"))
    }

    private var resolvedElsewhere = false

    func resolveFromElsewhere(id: String, answers: [String: [String]]) async {
        self.resolvedElsewhere = true
        await self.questionUpdate?(.resolved(.init(id: id, status: .answered, answers: .init(answers))))
    }

    func answerQuestion(id: String, answers: GatewayQuestionAnswers) async throws {
        self.answers.append(Answer(id: id, answers: answers))
    }

    func cancelQuestion(id: String) async throws {
        self.cancels.append(id)
    }

    func answered() -> [Answer] { self.answers }
    func cancelled() -> [String] { self.cancels }
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

/// A send that only returns when the connection is let go, as a frozen
/// socket does. Later sends answer at once.
private actor FrozenUntilLetGoGateway: ChatGateway {
    private var deliveries = 0
    private var letGo = 0
    private var frozen: CheckedContinuation<Void, Never>?
    func deliver(_ entry: OutboxEntry, update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws {
        self.deliveries += 1
        if self.deliveries == 1 {
            await withCheckedContinuation { self.frozen = $0 }
            throw ChatGatewayError.offline
        }
        await update(.accepted)
        await update(.reply("Reply \(self.deliveries)"))
    }
    func letGoOfConnection() async { self.letGo += 1; self.frozen?.resume(); self.frozen = nil }
    func deliveryCount() -> Int { self.deliveries }
    func letGoCount() -> Int { self.letGo }
}

/// The runtime folds a message sent mid-run into that run: one reply, and
/// the joined message's own request ends with nothing to show.
private actor JoiningGateway: ChatGateway {
    private var joined: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var started = false
    func deliver(_ entry: OutboxEntry, update: @escaping @Sendable (ChatDeliveryUpdate) async -> Void) async throws {
        if self.joined.contains(entry.text) { await update(.joinedEarlierReply); return }
        self.started = true
        await update(.accepted)
        await withCheckedContinuation { self.held = $0 }
        await update(.reply("One reply covering both"))
    }
    func addToRunningRequest(_ entry: OutboxEntry) async throws { self.joined.append(entry.text) }
    func deliveryStarted() -> Bool { self.started }
    func finishDelivery() { self.held?.resume(); self.held = nil }
    func joinedTexts() -> [String] { self.joined }
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
