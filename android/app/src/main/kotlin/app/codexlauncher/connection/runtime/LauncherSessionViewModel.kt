package app.codexlauncher.connection.runtime

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.codexlauncher.capability.interaction.CapabilityEffect
import app.codexlauncher.capability.interaction.CapabilityInteraction
import app.codexlauncher.capability.interaction.PromptDestination
import app.codexlauncher.connection.pairing.network.PairedComputer
import app.codexlauncher.connection.protocol.MessageType
import app.codexlauncher.connection.protocol.ProtocolCodec
import app.codexlauncher.connection.protocol.ProtocolMessage
import app.codexlauncher.connection.session.SessionConnection
import app.codexlauncher.connection.session.SessionFailure
import app.codexlauncher.connection.session.SessionObserver
import app.codexlauncher.connection.state.ConnectionEvent
import app.codexlauncher.connection.state.ConnectionSnapshot
import app.codexlauncher.connection.state.ConnectionStateMachine
import app.codexlauncher.diagnostics.AppLog
import app.codexlauncher.decision.approval.ApprovalViewModel
import app.codexlauncher.decision.approval.DecisionOutcome
import app.codexlauncher.project.selection.ProjectChoice
import app.codexlauncher.project.selection.ProjectSelectionViewModel
import app.codexlauncher.project.session.ProjectSessionBridge
import app.codexlauncher.project.session.ProjectSnapshot
import app.codexlauncher.storage.actions.ActionJournal
import app.codexlauncher.storage.connection.lastseen.shouldRecordSuccessfulConnection
import app.codexlauncher.task.summary.TaskEventReducer
import app.codexlauncher.task.summary.TaskQueueState
import app.codexlauncher.task.summary.TaskState
import app.codexlauncher.task.management.TaskAction
import app.codexlauncher.task.management.TaskActionBridge
import app.codexlauncher.task.management.TaskActionOutcome
import app.codexlauncher.task.configuration.NewTaskOptions
import app.codexlauncher.task.configuration.NewTaskSelection
import app.codexlauncher.task.control.NewTaskSendOutcome
import app.codexlauncher.task.control.TaskControlViewModel
import app.codexlauncher.launcher.home.sortedForHome
import app.codexlauncher.task.control.ExistingTaskControlOutcome
import app.codexlauncher.task.control.ExistingTaskSendMode
import app.codexlauncher.task.composer.DraftVersion
import app.codexlauncher.task.attachments.AttachmentSelection
import app.codexlauncher.task.attachments.AttachmentUploader
import app.codexlauncher.task.transcript.TranscriptEntry
import app.codexlauncher.task.transcript.TaskTranscriptMapper
import app.codexlauncher.task.transcript.TaskTranscriptUiState
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

data class LauncherSessionState(
    val connection: ConnectionSnapshot = ConnectionSnapshot.initial(),
    val snapshot: ProjectSnapshot? = null,
    val transcript: TaskTranscriptUiState? = null,
    val taskManagementAvailable: Boolean = false,
    val taskControlsAvailable: Boolean = false,
    val newTaskOptions: NewTaskOptions? = null,
    val newTaskOptionsSessionId: String? = null,
    val newTaskNeedsReview: Boolean = false,
    val newTaskMessage: String? = null,
    val unconfirmedForkTaskIds: Set<String> = emptySet(),
    val unconfirmedControlTaskIds: Set<String> = emptySet(),
    val followUpDraft: String = "",
)

class LauncherSessionViewModel(
    private val connect: (PairedComputer, String, SessionObserver) -> SessionConnection,
    private val loadProject: suspend () -> ProjectChoice?,
    saveProject: suspend (ProjectChoice) -> Boolean,
    clearProject: suspend () -> Boolean,
    private val actionJournal: ActionJournal,
    private val carryOutDeviceReply: (handle: String, text: String) -> String = { _, _ -> "refused" },
    private val carryOutYouTubePlayback: (watchUrl: String) -> String = { "refused" },
    private val fetchLocation: suspend () -> String = { "" },
    private val clearConfirmedDraft: suspend (DraftVersion) -> Boolean = { false },
    private val onSuccessfulConnection: suspend (pairingGeneration: String, epochMillis: Long) -> Unit = { _, _ -> },
    private val recordResumeCursor: suspend (pairingGeneration: String, throughSequence: Long) -> Boolean = { _, _ -> true },
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val nextSessionId: () -> String = { UUID.randomUUID().toString() },
    private val retryWait: suspend (attempt: Int) -> Unit = { attempt -> delay(retryDelayMillis(attempt)) },
    private val transcriptRefreshWait: suspend () -> Unit = { delay(TRANSCRIPT_REFRESH_MILLIS) },
    private val attachmentUploader: AttachmentUploader = AttachmentUploader(),
    workScope: CoroutineScope? = null,
) : ViewModel() {
    private val mutableState = MutableStateFlow(LauncherSessionState())
    private val generation = AtomicLong()
    private val submissionScope = workScope ?: viewModelScope
    private var snapshotScope = newSnapshotScope()
    private var activeDeviceId: String? = null
    private var activePairingGeneration: String? = null
    private var activeConnection: SessionConnection? = null
    private var projectBridge: ProjectSessionBridge? = null
    private var transcriptCapable = false
    private var taskManagementCapable = false
    private var attachmentCapable = false
    private var decisionCapable = false
    private var capabilityActionsCapable = false
    private var maxAttachmentBytes = ProtocolCodec.MAX_ATTACHMENT_BYTES.toLong()
    private var taskActionBridge: TaskActionBridge? = null
    private var taskControlViewModel: TaskControlViewModel? = null
    private val pendingTaskAcknowledgements = ConcurrentHashMap<String, TaskAcknowledgement>()
    private val retainedUnknownActionIds = ConcurrentHashMap.newKeySet<String>()
    private var pendingTranscript: PendingTranscriptRequest? = null
    private var pendingForkTaskId: String? = null
    private var transcriptRefreshQueued = false
    private var pendingDecisionRead: PendingDecisionRequest? = null
    private val acknowledgementGate = SequenceAcknowledgementGate()
    private val acknowledgementMutex = Mutex()
    private val pendingProjectAcknowledgement = AtomicReference<ProjectAcknowledgement?>()
    private val publishedProject = AtomicReference<ProjectChoice?>()
    private val storedProjectBaseline = AtomicReference<ProjectChoice?>()
    private val pendingTaskEvents = ArrayDeque<ProtocolMessage>()
    private val followUpDrafts = ConcurrentHashMap<String, String>()
    private var nextSnapshotToken = 0L
    private var pendingSnapshotToken: Long? = null
    private var retryJob: Job? = null
    private var transcriptRefreshJob: Job? = null
    private var retryComputer: PairedComputer? = null
    private var retryAttempt = 0
    private var retryToken = 0L

    val state: StateFlow<LauncherSessionState> = mutableState.asStateFlow()
    private val mutableNeedsLocationPermission = MutableStateFlow(false)
    val needsLocationPermission: StateFlow<Boolean> = mutableNeedsLocationPermission.asStateFlow()

    fun consumeLocationPermissionRequest() {
        mutableNeedsLocationPermission.value = false
    }

    val attachments = attachmentUploader.state
    private val capabilityController =
        CapabilityInteraction(
            sendAction = { encoded, beforeBoundary ->
                activeConnection?.sendAction(encoded, beforeBoundary)
                    ?: app.codexlauncher.connection.session.ActionSendResult.NOT_SENT
            },
        )
    val capabilityInteraction = capabilityController.state
    private var pendingHomePrompt: PendingHomePrompt? = null
    private val decisionViewModel =
        ApprovalViewModel(
            sendAction = { encoded, beforeBoundary -> activeConnection?.sendAction(encoded, beforeBoundary) ?: app.codexlauncher.connection.session.ActionSendResult.NOT_SENT },
            journal = actionJournal,
            onTerminalReceived = acknowledgementGate::block,
            onTerminalStored = { actionId, sequence, retainUnresolved ->
                taskActionStored(generation.get(), actionId, sequence, requiresSnapshot = false, retainUnresolved = retainUnresolved)
            },
        )
    val decisions = decisionViewModel.state
    val projectSelection =
        ProjectSelectionViewModel(
            select = ::selectProject,
            save = saveProject,
            clear = clearProject,
            afterSelectionApplied = ::acknowledgeProjectResult,
            workScope = submissionScope,
        )

    @Synchronized
    fun connect(paired: PairedComputer, force: Boolean = false) {
        cancelRetry(resetAttempts = true)
        retryComputer = paired
        startConnection(paired, force)
    }

    /**
     * True when the live session is already this exact endpoint and online, so a
     * send can reuse the warm socket instead of forcing a teardown+reconnect. The
     * Home send handler used to force a reconnect on every phone-agent send, which
     * closed and rebuilt the socket (fresh TLS + snapshot re-sync) each time and
     * added seconds of dead-wait before the prompt even left. It only needs to
     * force when the active connection is a different (possibly offline) endpoint.
     */
    fun isOnlineTo(deviceId: String): Boolean =
        activeDeviceId == deviceId &&
            mutableState.value.connection.phase == app.codexlauncher.connection.state.ConnectionPhase.ONLINE

    @Synchronized
    fun reconnectNow(reason: String) {
        if (mutableState.value.connection.phase != app.codexlauncher.connection.state.ConnectionPhase.DISCONNECTED) {
            AppLog.info(
                feature = "connection-runtime",
                message = "immediate reconnect ignored",
                fields = mapOf("branch_reason" to reason, "decision" to "session_already_active"),
            )
            return
        }
        val paired = retryComputer
        if (paired == null) {
            AppLog.info(
                feature = "connection-runtime",
                message = "immediate reconnect ignored",
                fields = mapOf("branch_reason" to reason, "decision" to "no_paired_computer"),
            )
            return
        }
        cancelRetry(resetAttempts = false)
        AppLog.info(
            feature = "connection-runtime",
            message = "immediate companion reconnect requested",
            fields = mapOf("branch_reason" to reason, "decision" to "open_fresh_session"),
        )
        startConnection(paired, force = true)
    }

    private fun startConnection(paired: PairedComputer, force: Boolean) {
        val current = mutableState.value.connection
        if (!force && activeDeviceId == paired.deviceId && current.phase != app.codexlauncher.connection.state.ConnectionPhase.DISCONNECTED) return
        closeCurrent(invalidate = true)
        activeDeviceId = paired.deviceId
        activePairingGeneration = paired.pairingGeneration
        mutableState.value = LauncherSessionState(ConnectionStateMachine.reduce(ConnectionSnapshot.initial(), ConnectionEvent.ConnectRequested))
        val currentGeneration = generation.get()
        val sessionId = nextSessionId()
        val observer = observer(currentGeneration, sessionId, paired.pairingGeneration)
        AppLog.info(
            feature = "connection-runtime",
            message = "companion connection requested",
            fields = mapOf("device_id" to paired.deviceId, "session_id" to sessionId, "input_shape" to "paired_computer"),
        )
        try {
            val opened = connect(paired, sessionId, observer)
            if (generation.get() == currentGeneration) activeConnection = opened else opened.close()
        } catch (error: Exception) {
            AppLog.error(
                feature = "connection-runtime",
                message = "companion connection could not start",
                error = error,
                fields = mapOf("device_id" to paired.deviceId, "decision" to "show_computer_offline"),
            )
            fail(currentGeneration, SessionFailure.CONNECTION_LOST)
        }
    }

    @Synchronized
    fun disconnect() {
        cancelRetry(resetAttempts = true)
        retryComputer = null
        attachmentUploader.clearAll()
        closeCurrent(invalidate = true)
        mutableState.value = LauncherSessionState(ConnectionStateMachine.reduce(mutableState.value.connection, ConnectionEvent.ConnectionLost))
    }

    private fun observer(
        expectedGeneration: Long,
        sessionId: String,
        pairingGeneration: String,
    ) =
        object : SessionObserver {
            override fun onReady(connection: SessionConnection, attachmentKey: ByteArray) {
                try {
                    if (generation.get() != expectedGeneration) {
                        connection.close()
                        return
                    }
                    activeConnection = connection
                    attachmentUploader.attach(sessionId, attachmentKey, connection)
                    projectBridge?.close()
                    projectBridge = null
                    mutableState.value = mutableState.value.copy(
                        connection = ConnectionStateMachine.reduce(mutableState.value.connection, ConnectionEvent.SocketAuthenticated),
                    )
                    AppLog.info(
                        feature = "connection-runtime",
                        message = "companion socket authenticated",
                        fields = mapOf("decision" to "await_fresh_snapshot"),
                    )
                } finally {
                    attachmentKey.fill(0)
                }
            }

            override fun onMessage(message: ProtocolMessage) {
                if (generation.get() != expectedGeneration) return
                when (message.type) {
                    MessageType.WELCOME -> acceptCapabilities(expectedGeneration, message)
                    MessageType.SNAPSHOT -> applySnapshot(expectedGeneration, pairingGeneration, message)
                    MessageType.EVENT -> applyTaskEvent(expectedGeneration, message)
                    MessageType.TASK_PAGE -> applyTaskPage(expectedGeneration, message)
                    MessageType.DECISION_PAGE -> applyDecisionPage(expectedGeneration, message)
                    MessageType.ACTION_RESULT -> {
                        acceptCapabilityActionResult(expectedGeneration, message)
                        decisionViewModel.acceptActionResult(message)
                        projectBridge?.accept(message)
                        taskActionBridge?.accept(message)
                        taskControlViewModel?.accept(message)
                    }
                    MessageType.CAPABILITY_PREVIEW -> capabilityController.acceptPreview(message)
                    MessageType.CAPABILITY_RESULT -> acceptCapabilityResult(expectedGeneration, message)
                    MessageType.DEVICE_ACTION -> handleDeviceAction(expectedGeneration, message)
                    MessageType.ATTACHMENT_ACK -> {
                        attachmentUploader.accept(message)
                        val sequence = message.sequence
                        if (sequence == null) {
                            fail(expectedGeneration, SessionFailure.INVALID_PROTOCOL)
                        } else {
                            submissionScope.launch { acknowledge(expectedGeneration, sequence) }
                        }
                    }
                    else -> Unit
                }
            }

            override fun onFailure(reason: SessionFailure) = fail(expectedGeneration, reason)

            override fun onClosed() = fail(expectedGeneration, SessionFailure.CONNECTION_LOST)
        }

    private fun acceptCapabilities(expectedGeneration: Long, message: ProtocolMessage) {
        val capabilities = message.body.getValue("capabilities").jsonArray.map { it.jsonPrimitive.content }
        if ("set_project" !in capabilities) {
            AppLog.info(
                feature = "connection-runtime",
                message = "required companion capability is unavailable",
                fields = mapOf("required_capability" to "set_project", "decision" to "show_incompatible_version"),
            )
            fail(expectedGeneration, SessionFailure.INVALID_PROTOCOL)
            return
        }
        transcriptCapable = "task_transcripts" in capabilities
        taskManagementCapable = "task_management" in capabilities
        attachmentCapable = "attachments" in capabilities
        decisionCapable = "decisions" in capabilities
        capabilityActionsCapable = "capability_actions" in capabilities
        maxAttachmentBytes =
            message.body["limits"]?.jsonObject?.get("maxAttachmentBytes")?.jsonPrimitive?.longOrNull
                ?.coerceAtMost(ProtocolCodec.MAX_ATTACHMENT_BYTES.toLong())
                ?: ProtocolCodec.MAX_ATTACHMENT_BYTES.toLong()
        val taskControlsCapable = "desktop_tasks" in capabilities
        capabilityController.setComputerFallbackEnabled(taskControlsCapable)
        val newTaskOptions =
            if ("new_task_options" in capabilities) NewTaskOptions.fromWelcome(message.body) else null
        mutableState.value =
            mutableState.value.copy(
                newTaskOptions = newTaskOptions,
                newTaskOptionsSessionId = newTaskOptions?.let { message.body.getValue("sessionId").jsonPrimitive.content },
                taskControlsAvailable = taskControlsCapable,
            )
        AppLog.info(
            feature = "new-task-options",
            message = "host task options accepted",
            fields = mapOf(
                "model_count" to (newTaskOptions?.models?.size ?: 0),
                "permission_mode_count" to (newTaskOptions?.permissionModes?.size ?: 0),
                "decision" to if (newTaskOptions == null) "hide_option_controls" else "show_host_options",
            ),
        )
        val connection = activeConnection ?: return
        projectBridge =
            ProjectSessionBridge(
                sendAction = connection::sendAction,
                journal = actionJournal,
                onTerminalReceived = { actionId, sequence ->
                    acknowledgementGate.block(actionId, sequence)
                },
                onTerminalResult = { actionId, sequence ->
                    pendingProjectAcknowledgement.set(ProjectAcknowledgement(expectedGeneration, actionId, sequence))
                },
            )
        taskActionBridge =
            if (taskManagementCapable) {
                TaskActionBridge(
                    sendAction = connection::sendAction,
                    journal = actionJournal,
                    onTerminalReceived = acknowledgementGate::block,
                    onTerminalStored = { actionId, sequence, requiresSnapshot, retainUnresolved ->
                        taskActionStored(expectedGeneration, actionId, sequence, requiresSnapshot, retainUnresolved)
                    },
                )
            } else {
                null
            }
        taskControlViewModel =
            if (taskControlsCapable || newTaskOptions != null) {
                TaskControlViewModel(
                    sendAction = connection::sendAction,
                    journal = actionJournal,
                    clearConfirmedDraft = clearConfirmedDraft,
                    onTerminalReceived = acknowledgementGate::block,
                    onTerminalStored = { actionId, sequence, requiresSnapshot, retainUnresolved ->
                        taskActionStored(expectedGeneration, actionId, sequence, requiresSnapshot, retainUnresolved)
                    },
                )
            } else {
                null
            }
        taskControlViewModel?.let { controls ->
            submissionScope.launch {
                publishNewTaskReview(expectedGeneration, controls.needsNewTaskReview())
                publishUnconfirmedTaskControls(expectedGeneration, controls.unresolvedExistingTaskIds())
            }
        }
        taskActionBridge?.let { bridge ->
            submissionScope.launch {
                publishUnconfirmedForks(expectedGeneration, bridge.unresolvedForkTaskIds())
            }
        }
    }

    suspend fun renameTask(taskId: String, title: String): TaskActionOutcome =
        performTaskAction(taskId, TaskAction.Rename(title))

    suspend fun archiveTask(taskId: String): TaskActionOutcome =
        performTaskAction(taskId, TaskAction.Archive)

    suspend fun forkTask(taskId: String): TaskActionOutcome =
        performTaskAction(taskId, TaskAction.Fork)

    fun addAttachment(displayName: String, mediaType: String, bytes: ByteArray): AttachmentSelection {
        if (!attachmentCapable) return AttachmentSelection.Invalid
        return attachmentUploader.select(displayName, mediaType, bytes, maxAttachmentBytes)
    }

    fun removeAttachment(uploadId: String): Boolean = attachmentUploader.remove(uploadId)

    fun clearAttachments() = attachmentUploader.clearAll()

    @Synchronized
    fun attachmentLimitBytes(): Long = if (attachmentCapable) maxAttachmentBytes else 0

    suspend fun prepareAttachments(): List<String>? {
        if (!attachmentCapable) return if (attachments.value.isEmpty()) emptyList() else null
        for (attachment in attachments.value) {
            if (attachment.phase != app.codexlauncher.task.attachments.AttachmentPhase.COMPLETE &&
                !attachmentUploader.upload(attachment.id)
            ) return null
        }
        return attachmentUploader.completedIds()
    }

    suspend fun startNewTask(prompt: String, selection: NewTaskSelection, draftVersion: DraftVersion): NewTaskSendOutcome {
        val current = mutableState.value
        val projectId = current.connection.selectedProjectId ?: return NewTaskSendOutcome.Unavailable
        val options = current.newTaskOptions ?: return NewTaskSendOutcome.Unavailable
        if (options.normalize(selection) != selection) return NewTaskSendOutcome.Invalid
        val controls = taskControlViewModel ?: return NewTaskSendOutcome.Unavailable
        val attachmentIds = prepareAttachments() ?: return NewTaskSendOutcome.Unavailable
        mutableState.value = mutableState.value.copy(newTaskMessage = null)
        val outcome = controls.startNewTask(projectId, prompt, selection, draftVersion, attachmentIds)
        finishNewTaskAttachments(attachmentIds, outcome)
        if (outcome == NewTaskSendOutcome.NeedsReview) publishNewTaskReview(generation.get(), true)
        mutableState.value = mutableState.value.copy(newTaskMessage = newTaskMessage(outcome))
        return outcome
    }

    fun setPromptDestination(destination: PromptDestination): Boolean =
        capabilityController.setDestination(destination)

    suspend fun submitHomePrompt(
        prompt: String,
        selection: NewTaskSelection?,
        draftVersion: DraftVersion,
        forceCapability: Boolean = false,
    ) {
        val routeThroughApps =
            forceCapability ||
                (capabilityActionsCapable && capabilityInteraction.value.destination == PromptDestination.AUTO)
        if (!routeThroughApps) {
            if (selection == null) {
                AppLog.info(
                    feature = "capability-interaction",
                    message = "home computer send missing selection",
                    fields = mapOf("prompt_length" to prompt.length),
                )
                return
            }
            if (!mutableState.value.taskControlsAvailable) {
                AppLog.info(
                    feature = "capability-interaction",
                    message = "home prompt kept local because phone runtime has no desktop tasks",
                    fields = mapOf(
                        "destination" to capabilityInteraction.value.destination.name.lowercase(),
                        "capability_available" to capabilityActionsCapable,
                        "prompt_length" to prompt.length,
                    ),
                )
                return
            }
            AppLog.info(
                feature = "capability-interaction",
                message = "home prompt sent directly to paired computer",
                fields = mapOf(
                    "destination" to capabilityInteraction.value.destination.name.lowercase(),
                    "capability_available" to capabilityActionsCapable,
                    "prompt_length" to prompt.length,
                ),
            )
            startNewTask(prompt, selection, draftVersion)
            return
        }

        if (forceCapability) {
            submitHomePromptToPhoneAgent(prompt, draftVersion)
            return
        }

        synchronized(this) {
            if (pendingHomePrompt != null) return
            pendingHomePrompt = PendingHomePrompt(prompt, selection, draftVersion)
        }
        val requestId = capabilityController.request(prompt)
        if (requestId != null) return
        val fallback = synchronized(this) { pendingHomePrompt.also { pendingHomePrompt = null } } ?: return
        val selection = fallback.selection
        if (!mutableState.value.taskControlsAvailable || selection == null) {
            AppLog.info(
                feature = "capability-interaction",
                message = "app action route unavailable; kept local on standalone phone",
                fields = mapOf("prompt_length" to fallback.prompt.length),
            )
            return
        }
        startNewTask(fallback.prompt, selection, fallback.draftVersion)
    }

    /**
     * On-phone Send. The phone runtime advertises `desktop_tasks` but no project
     * and no `new_task_options`, so `startNewTask` cannot run here. The prompt
     * goes to the phone agent's one existing task as a queued start_turn; its id
     * comes from the same task list Home renders, so it tracks the runtime rather
     * than hardcoding the runtime's own `"phone-agent"` constant. A durable
     * confirmation clears the composer draft. (Phase 8 deleted the capability wire
     * this branch used to take; `capabilityController.request()` self-rejects now.)
     */
    private suspend fun submitHomePromptToPhoneAgent(prompt: String, draftVersion: DraftVersion) {
        val taskId = mutableState.value.snapshot?.tasks?.sortedForHome()?.firstOrNull()?.id
        if (taskId == null) {
            AppLog.info(
                feature = "standalone",
                message = "home prompt has no phone task to receive it",
                fields = mapOf(
                    "task_controls_available" to mutableState.value.taskControlsAvailable,
                    "prompt_length" to prompt.length,
                ),
            )
            return
        }
        val outcome = queueTaskFollowUp(taskId, prompt)
        val delivered =
            outcome is ExistingTaskControlOutcome.Accepted || outcome is ExistingTaskControlOutcome.Queued
        if (delivered) {
            clearConfirmedDraft(draftVersion)
            markTaskWorkingOptimistically(taskId)
        }
        AppLog.info(
            feature = "standalone",
            message = "home prompt sent to phone agent task",
            fields = mapOf(
                "task_id" to taskId,
                "outcome" to outcome::class.simpleName.orEmpty(),
                "prompt_length" to prompt.length,
            ),
        )
    }

    @Synchronized
    private fun acceptCapabilityActionResult(expectedGeneration: Long, message: ProtocolMessage) {
        val effect = capabilityController.acceptActionResult(message)
        if (effect == CapabilityEffect.None) return
        val sequence = message.sequence
        if (sequence == null) {
            fail(expectedGeneration, SessionFailure.INVALID_PROTOCOL)
            return
        }
        val pending = pendingHomePrompt
        pendingHomePrompt = null
        submissionScope.launch {
            acknowledge(expectedGeneration, sequence)
            if (effect is CapabilityEffect.FallbackToComputer && pending != null) {
                if (!mutableState.value.taskControlsAvailable) {
                    AppLog.info(
                        feature = "capability-interaction",
                        message = "app action route did not match; kept local on standalone phone",
                        fields = mapOf(
                            "request_id" to effect.requestId,
                            "decision" to "unsupported_locally",
                            "prompt_length" to pending.prompt.length,
                        ),
                    )
                    return@launch
                }
                AppLog.info(
                    feature = "capability-interaction",
                    message = "app action route did not match",
                    fields = mapOf(
                        "request_id" to effect.requestId,
                        "decision" to "start_codex_task",
                        "prompt_length" to pending.prompt.length,
                    ),
                )
                pending.selection?.let { startNewTask(pending.prompt, it, pending.draftVersion) }
            } else {
                AppLog.info(
                    feature = "capability-interaction",
                    message = "app action confirmation reached a terminal result",
                    fields = mapOf(
                        "result" to effect::class.simpleName.orEmpty(),
                        "decision" to "keep_draft_without_fallback",
                    ),
                )
            }
        }
    }

    @Synchronized
    private fun acceptCapabilityResult(expectedGeneration: Long, message: ProtocolMessage) {
        val outcome = capabilityController.acceptResult(message) ?: return
        val sequence = message.sequence
        if (sequence == null) {
            fail(expectedGeneration, SessionFailure.INVALID_PROTOCOL)
            return
        }
        val pending = pendingHomePrompt
        pendingHomePrompt = null
        submissionScope.launch {
            // Throw someone's words away only when we know the thing they
            // wanted actually happened. "Not a failure" is a wider net than it
            // looks: a one-tap result has staged something and sent nothing —
            // there is still a button to press — and a hand-off means we
            // stopped being able to see what happened. Both used to delete the
            // draft, which is exactly when the person is most likely to want
            // it back. Only a finished `completes` run claims success.
            if (pending != null && outcome.claimsSuccess) {
                clearConfirmedDraft(pending.draftVersion)
            }
            acknowledge(expectedGeneration, sequence)
            AppLog.info(
                feature = "capability-interaction",
                message = "app action result published",
                fields = mapOf(
                    "sequence" to sequence,
                    "ceiling" to outcome.ceiling.wireName,
                    "claims_success" to outcome.claimsSuccess,
                    "claims_failure" to outcome.claimsFailure,
                ),
            )
        }
    }

    suspend fun queueTaskFollowUp(taskId: String, prompt: String): ExistingTaskControlOutcome {
        val attachmentIds = prepareAttachments() ?: return ExistingTaskControlOutcome.Unavailable
        val outcome = taskControlViewModel?.sendToTask(taskId, prompt, ExistingTaskSendMode.QUEUE, attachmentIds) ?: ExistingTaskControlOutcome.Unavailable
        finishExistingTaskAttachments(attachmentIds, outcome)
        if (outcome == ExistingTaskControlOutcome.Queued) publishTaskQueueState(taskId, TaskQueueState.QUEUED)
        if (outcome == ExistingTaskControlOutcome.NeedsReview) publishTaskQueueState(taskId, TaskQueueState.OUTCOME_UNKNOWN)
        return outcome
    }

    suspend fun redirectTask(taskId: String, prompt: String): ExistingTaskControlOutcome {
        val attachmentIds = prepareAttachments() ?: return ExistingTaskControlOutcome.Unavailable
        val outcome = taskControlViewModel?.sendToTask(taskId, prompt, ExistingTaskSendMode.REDIRECT, attachmentIds) ?: ExistingTaskControlOutcome.Unavailable
        finishExistingTaskAttachments(attachmentIds, outcome)
        if (outcome == ExistingTaskControlOutcome.Queued) publishTaskQueueState(taskId, TaskQueueState.QUEUED)
        if (outcome == ExistingTaskControlOutcome.NeedsReview) publishTaskQueueState(taskId, TaskQueueState.OUTCOME_UNKNOWN)
        return outcome
    }

    private fun finishNewTaskAttachments(ids: List<String>, outcome: NewTaskSendOutcome) {
        when (outcome) {
            NewTaskSendOutcome.Complete, NewTaskSendOutcome.CompleteDraftRetained, NewTaskSendOutcome.NeedsReview ->
                attachmentUploader.consume(ids)
            is NewTaskSendOutcome.Failed -> attachmentUploader.retryAfterActionFailure(ids)
            NewTaskSendOutcome.Invalid, NewTaskSendOutcome.Unavailable -> Unit
        }
    }

    private fun finishExistingTaskAttachments(ids: List<String>, outcome: ExistingTaskControlOutcome) {
        when (outcome) {
            ExistingTaskControlOutcome.Accepted, ExistingTaskControlOutcome.Queued,
            ExistingTaskControlOutcome.Redirected, ExistingTaskControlOutcome.NeedsReview -> attachmentUploader.consume(ids)
            is ExistingTaskControlOutcome.Failed -> attachmentUploader.retryAfterActionFailure(ids)
            ExistingTaskControlOutcome.Interrupted, ExistingTaskControlOutcome.Invalid,
            ExistingTaskControlOutcome.Unavailable -> Unit
        }
    }

    suspend fun stopTask(taskId: String): ExistingTaskControlOutcome {
        val outcome = taskControlViewModel?.stopTask(taskId) ?: ExistingTaskControlOutcome.Unavailable
        if (outcome == ExistingTaskControlOutcome.NeedsReview) publishTaskQueueState(taskId, TaskQueueState.OUTCOME_UNKNOWN)
        return outcome
    }

    @Synchronized
    private fun publishTaskQueueState(taskId: String, queueState: TaskQueueState) {
        val current = mutableState.value
        val snapshot = current.snapshot ?: return
        val index = snapshot.tasks.indexOfFirst { it.id == taskId }
        if (index < 0) return
        val tasks = snapshot.tasks.toMutableList()
        tasks[index] = tasks[index].copy(queueState = queueState)
        mutableState.value = current.copy(snapshot = snapshot.copy(tasks = tasks))
    }

    /**
     * Optimistically show a just-submitted task as WORKING so the user gets
     * instant feedback instead of a stale "Replied" (or nothing) for the whole
     * pre-first-token dead-wait. The runtime does not push a working event until
     * the reply starts, so without this the phone looks frozen for ~20s after a
     * send. The first real [TaskEventReducer] event supersedes this the moment it
     * arrives, so a wrong optimistic guess self-corrects; we only set it when the
     * send was actually delivered.
     */
    private fun markTaskWorkingOptimistically(taskId: String) {
        val current = mutableState.value
        val snapshot = current.snapshot ?: return
        val index = snapshot.tasks.indexOfFirst { it.id == taskId }
        if (index < 0) return
        val existing = snapshot.tasks[index]
        if (existing.state == TaskState.WORKING) return
        val tasks = snapshot.tasks.toMutableList()
        tasks[index] = existing.copy(state = TaskState.WORKING)
        mutableState.value = current.copy(snapshot = snapshot.copy(tasks = tasks))
    }

    suspend fun dismissUnconfirmedNewTask(): Boolean {
        val controls = taskControlViewModel ?: return false
        if (!controls.dismissUnresolvedNewTasks()) return false
        return publishNewTaskReview(generation.get(), false)
    }

    suspend fun dismissUnconfirmedTaskControl(taskId: String): Boolean {
        val controls = taskControlViewModel ?: return false
        if (!controls.dismissUnresolvedExistingTask(taskId)) return false
        val remaining = controls.unresolvedExistingTaskIds()
        if (!publishUnconfirmedTaskControls(generation.get(), remaining)) return false
        if (taskId !in remaining) publishTaskQueueState(taskId, TaskQueueState.NONE)
        return true
    }

    @Synchronized
    private fun publishUnconfirmedTaskControls(expectedGeneration: Long, taskIds: Set<String>): Boolean {
        if (generation.get() != expectedGeneration) return false
        val current = mutableState.value
        val snapshot = current.snapshot
        val tasks = snapshot?.tasks?.map { task -> if (task.id in taskIds) task.copy(queueState = TaskQueueState.OUTCOME_UNKNOWN) else task }
        mutableState.value = current.copy(
            snapshot = if (snapshot != null && tasks != null) snapshot.copy(tasks = tasks) else snapshot,
            unconfirmedControlTaskIds = taskIds,
        )
        return true
    }

    @Synchronized
    private fun publishNewTaskReview(expectedGeneration: Long, needsReview: Boolean): Boolean {
        if (generation.get() != expectedGeneration) return false
        mutableState.value = mutableState.value.copy(newTaskNeedsReview = needsReview)
        return true
    }

    suspend fun dismissUnconfirmedFork(taskId: String): Boolean {
        val request = currentTaskActionRequest(taskId) ?: return false
        if (!request.bridge.dismissUnresolvedFork(taskId)) return false
        return publishUnconfirmedForks(request.generation, request.bridge.unresolvedForkTaskIds())
    }

    private suspend fun performTaskAction(taskId: String, action: TaskAction): TaskActionOutcome {
        val request = currentTaskActionRequest(taskId) ?: return TaskActionOutcome.NotSent
        val outcome = request.bridge.perform(taskId, action)
        if (action == TaskAction.Fork) {
            if (outcome is TaskActionOutcome.Forked) {
                pendingForkTaskId = outcome.taskId
                openPendingForkIfAvailable()
            } else {
                publishUnconfirmedForks(request.generation, request.bridge.unresolvedForkTaskIds())
            }
        }
        return outcome
    }

    @Synchronized
    private fun openPendingForkIfAvailable() {
        val taskId = pendingForkTaskId ?: return
        if (mutableState.value.snapshot?.tasks?.none { it.id == taskId } != false) return
        if (openTask(taskId)) {
            pendingForkTaskId = null
            AppLog.info(
                feature = "task-management",
                message = "confirmed fork opened",
                fields = mapOf("task_id" to taskId, "decision" to "show_fork_transcript"),
            )
        }
    }

    @Synchronized
    private fun publishUnconfirmedForks(expectedGeneration: Long, taskIds: Set<String>): Boolean {
        if (generation.get() != expectedGeneration) return false
        mutableState.value = mutableState.value.copy(unconfirmedForkTaskIds = taskIds)
        AppLog.info(
            feature = "task-management",
            message = "unconfirmed fork metadata published",
            fields = mapOf("task_count" to taskIds.size, "output_shape" to "durable_review_gate"),
        )
        return true
    }

    @Synchronized
    private fun currentTaskActionRequest(taskId: String): TaskActionRequest? {
        val current = mutableState.value
        if (!taskManagementCapable || current.connection.phase != app.codexlauncher.connection.state.ConnectionPhase.ONLINE ||
            current.snapshot?.tasks?.none { it.id == taskId } != false
        ) return null
        return taskActionBridge?.let { TaskActionRequest(generation.get(), it) }
    }

    @Synchronized
    fun openTask(taskId: String): Boolean {
        val current = mutableState.value
        val task = current.snapshot?.tasks?.singleOrNull { it.id == taskId }
        if (!transcriptCapable || current.connection.phase != app.codexlauncher.connection.state.ConnectionPhase.ONLINE || task == null) return false
        pendingDecisionRead = null
        stopTranscriptRefresh("open_another_task")
        decisionViewModel.clear()
        mutableState.value =
            current.copy(
                transcript = TaskTranscriptUiState(taskId = taskId, title = task.title),
                followUpDraft = followUpDrafts[taskId].orEmpty(),
            )
        val transcriptRequested = sendTranscriptRead(taskId, beforeEntryId = null, mode = TranscriptReadMode.INITIAL)
        val decisionsRequested = !decisionCapable || sendDecisionRead(taskId)
        if (transcriptRequested && decisionsRequested) startTranscriptRefresh(taskId, generation.get())
        return transcriptRequested && decisionsRequested
    }

    suspend fun respondToDecision(requestId: String, decision: String): DecisionOutcome = decisionViewModel.respond(requestId, decision)

    suspend fun answerDecision(requestId: String, answers: Map<String, List<String>>): DecisionOutcome = decisionViewModel.answer(requestId, answers)

    fun dismissQuestion(requestId: String): Boolean = decisionViewModel.dismissQuestion(requestId)

    fun reopenQuestion(requestId: String): Boolean = decisionViewModel.reopenQuestion(requestId)

    @Synchronized
    fun updateTaskFollowUpDraft(taskId: String, text: String): Boolean {
        val current = mutableState.value
        if (current.transcript?.taskId != taskId) return false
        if (text.isEmpty()) followUpDrafts.remove(taskId) else followUpDrafts[taskId] = text
        mutableState.value = current.copy(followUpDraft = text)
        AppLog.info(
            feature = "task-control",
            message = "in-memory follow-up draft updated",
            fields = mapOf("thread_id" to taskId, "text_length" to text.length, "storage" to "memory_only"),
        )
        return true
    }

    @Synchronized
    fun clearFollowUpDrafts() {
        val cleared = followUpDrafts.size
        followUpDrafts.clear()
        mutableState.value = mutableState.value.copy(followUpDraft = "")
        AppLog.info(
            feature = "task-control",
            message = "in-memory follow-up drafts cleared",
            fields = mapOf("draft_count" to cleared, "reason" to "explicit_local_wipe"),
        )
    }

    @Synchronized
    fun loadEarlierTranscript(): Boolean {
        val transcript = mutableState.value.transcript ?: return false
        val cursor = transcript.earlierCursor ?: return false
        if (transcript.loading) return false
        mutableState.value = mutableState.value.copy(transcript = transcript.copy(loading = true, errorCode = null))
        return sendTranscriptRead(transcript.taskId, beforeEntryId = cursor, mode = TranscriptReadMode.EARLIER)
    }

    @Synchronized
    fun closeTask() {
        stopTranscriptRefresh("task_closed")
        pendingTranscript = null
        transcriptRefreshQueued = false
        pendingDecisionRead = null
        decisionViewModel.clear()
        mutableState.value = mutableState.value.copy(transcript = null, followUpDraft = "")
    }

    private fun sendTranscriptRead(taskId: String, beforeEntryId: String?, mode: TranscriptReadMode): Boolean {
        val connection = activeConnection ?: return false
        val requestId = UUID.randomUUID().toString()
        val encoded =
            buildJsonObject {
                put("version", buildJsonObject { put("major", ProtocolCodec.PROTOCOL_MAJOR); put("minor", 0) })
                put("messageId", UUID.randomUUID().toString())
                put("sender", "phone")
                put("type", "task_read")
                put("body", buildJsonObject {
                    put("requestId", requestId)
                    put("taskId", taskId)
                    put("limit", TRANSCRIPT_PAGE_SIZE)
                    beforeEntryId?.let { put("beforeEntryId", it) }
                })
            }.toString().also(ProtocolCodec::decodeText)
        pendingTranscript = PendingTranscriptRequest(generation.get(), requestId, taskId, mode)
        if (!connection.sendText(encoded)) {
            fail(generation.get(), SessionFailure.CONNECTION_LOST)
            return false
        }
        AppLog.info(
            feature = "task-transcript",
            message = "transcript page requested",
            fields = mapOf(
                "task_id" to taskId,
                "has_cursor" to (beforeEntryId != null),
                "input_limit" to TRANSCRIPT_PAGE_SIZE,
                "read_mode" to mode.name.lowercase(),
            ),
        )
        return true
    }

    private fun startTranscriptRefresh(taskId: String, expectedGeneration: Long) {
        transcriptRefreshJob = submissionScope.launch {
            AppLog.info(
                feature = "task-transcript",
                message = "live transcript refresh started",
                fields = mapOf("task_id" to taskId, "interval_millis" to TRANSCRIPT_REFRESH_MILLIS),
            )
            while (true) {
                transcriptRefreshWait()
                requestTranscriptRefresh(expectedGeneration, taskId, "interval")
            }
        }
    }

    @Synchronized
    private fun requestTranscriptRefresh(expectedGeneration: Long, taskId: String, reason: String): Boolean {
        val current = mutableState.value
        if (
            generation.get() != expectedGeneration ||
            current.connection.phase != app.codexlauncher.connection.state.ConnectionPhase.ONLINE ||
            current.transcript?.taskId != taskId
        ) return false
        if (pendingTranscript != null) {
            transcriptRefreshQueued = true
            AppLog.info(
                feature = "task-transcript",
                message = "live transcript refresh coalesced",
                fields = mapOf("task_id" to taskId, "reason" to reason, "decision" to "refresh_after_pending_read"),
            )
            return true
        }
        AppLog.info(
            feature = "task-transcript",
            message = "live transcript refresh requested",
            fields = mapOf("task_id" to taskId, "reason" to reason),
        )
        return sendTranscriptRead(taskId, beforeEntryId = null, mode = TranscriptReadMode.REFRESH)
    }

    private fun stopTranscriptRefresh(reason: String) {
        transcriptRefreshQueued = false
        if (transcriptRefreshJob == null) return
        transcriptRefreshJob?.cancel()
        transcriptRefreshJob = null
        AppLog.info(
            feature = "task-transcript",
            message = "live transcript refresh stopped",
            fields = mapOf("reason" to reason),
        )
    }

    private fun sendDecisionRead(taskId: String): Boolean {
        val connection = activeConnection ?: return false
        val requestId = UUID.randomUUID().toString()
        val encoded =
            buildJsonObject {
                put("version", buildJsonObject { put("major", ProtocolCodec.PROTOCOL_MAJOR); put("minor", 0) })
                put("messageId", UUID.randomUUID().toString())
                put("sender", "phone")
                put("type", "decision_read")
                put("body", buildJsonObject { put("requestId", requestId); put("taskId", taskId) })
            }.toString().also(ProtocolCodec::decodeText)
        pendingDecisionRead = PendingDecisionRequest(generation.get(), requestId, taskId)
        if (!connection.sendText(encoded)) {
            fail(generation.get(), SessionFailure.CONNECTION_LOST)
            return false
        }
        AppLog.info("decision", "live decisions requested", mapOf("thread_id" to taskId, "storage" to "memory_only"))
        return true
    }

    @Synchronized
    private fun applyDecisionPage(expectedGeneration: Long, message: ProtocolMessage) {
        if (generation.get() != expectedGeneration) return
        val pending = pendingDecisionRead ?: return
        val requestId = message.body.getValue("requestId").jsonPrimitive.content
        val taskId = message.body.getValue("taskId").jsonPrimitive.content
        if (pending.generation != expectedGeneration || pending.requestId != requestId || pending.taskId != taskId) {
            fail(expectedGeneration, SessionFailure.INVALID_PROTOCOL)
            return
        }
        pendingDecisionRead = null
        decisionViewModel.acceptPage(message)
    }

    @Synchronized
    private fun applyTaskPage(expectedGeneration: Long, message: ProtocolMessage) {
        if (generation.get() != expectedGeneration) return
        val page = TaskTranscriptMapper.map(message)
        val pending = pendingTranscript ?: return
        if (page.requestId != pending.requestId) return
        if (pending.generation != expectedGeneration || page.taskId != pending.taskId) {
            fail(expectedGeneration, SessionFailure.INVALID_PROTOCOL)
            return
        }
        val current = mutableState.value.transcript
        if (current == null || current.taskId != pending.taskId) {
            pendingTranscript = null
            transcriptRefreshQueued = false
            return
        }
        pendingTranscript = null
        if (page.errorCode != null) {
            mutableState.value = mutableState.value.copy(
                transcript = current.copy(loading = false, errorCode = page.errorCode),
            )
            flushQueuedTranscriptRefresh(expectedGeneration, pending.taskId)
            return
        }
        val entries =
            when (pending.mode) {
                TranscriptReadMode.INITIAL -> page.entries
                TranscriptReadMode.EARLIER -> page.entries + current.entries
                TranscriptReadMode.REFRESH -> mergeRefreshedEntries(current.entries, page.entries)
            }
        if (entries.map { it.id }.distinct().size != entries.size) {
            fail(expectedGeneration, SessionFailure.INVALID_PROTOCOL)
            return
        }
        mutableState.value = mutableState.value.copy(
            transcript = current.copy(
                entries = entries,
                earlierCursor = if (pending.mode == TranscriptReadMode.REFRESH) current.earlierCursor else page.earlierCursor,
                truncated = current.truncated || page.truncated,
                loading = false,
                errorCode = null,
            ),
        )
        AppLog.info(
            feature = "task-transcript",
            message = "transcript page applied",
            fields = mapOf("task_id" to page.taskId, "page_count" to page.entries.size, "total_count" to entries.size, "has_earlier" to (page.earlierCursor != null)),
        )
        flushQueuedTranscriptRefresh(expectedGeneration, pending.taskId)
    }

    @Synchronized
    private fun flushQueuedTranscriptRefresh(expectedGeneration: Long, taskId: String) {
        if (!transcriptRefreshQueued) return
        transcriptRefreshQueued = false
        requestTranscriptRefresh(expectedGeneration, taskId, "coalesced")
    }

    private fun applySnapshot(
        expectedGeneration: Long,
        pairingGeneration: String,
        message: ProtocolMessage,
    ) {
        val bridge = projectBridge ?: return
        val snapshot = bridge.snapshot(message)
        val snapshotTicket = beginSnapshot(expectedGeneration, snapshot.baseSequence) ?: return
        snapshotScope.launch {
            val loadedProject =
                try {
                    loadProject()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    AppLog.error(
                        feature = "connection-runtime",
                        message = "stored project could not be loaded",
                        error = error,
                        fields = mapOf(
                            "snapshot_kind" to if (snapshotTicket.isRefresh) "refresh" else "initial",
                            "decision" to if (snapshotTicket.retainedProject == null) "require_project_selection" else "keep_published_selection",
                        ),
                    )
                    null
                }
            if (!retainLoadedProject(expectedGeneration, snapshotTicket.token, loadedProject)) return@launch
            val retainedProject = snapshotTicket.retainedProject ?: storedProjectBaseline.get()
            val stored = retainedProject ?: loadedProject
            projectSelection.applySnapshot(
                computerName = snapshot.computerName,
                choices = snapshot.projects,
                stored = stored,
                ensureStoredSelection = snapshotTicket.supersedesSnapshot && retainedProject != null,
            )
            if (!isCurrentSnapshot(expectedGeneration, snapshotTicket.token)) return@launch
            var connection = mutableState.value.connection
            val previousProject = connection.selectedProjectId
            val selectedProject = projectSelection.state.value.selectedProjectId
            connection =
                when {
                    selectedProject != null -> ConnectionStateMachine.reduce(connection, ConnectionEvent.ProjectSelected(selectedProject))
                    previousProject != null -> ConnectionStateMachine.reduce(connection, ConnectionEvent.ProjectUnavailable(previousProject))
                    else -> connection
                }
            connection = ConnectionStateMachine.reduce(connection, ConnectionEvent.SnapshotApplied(snapshot.baseSequence))
            val becameOnline = shouldRecordSuccessfulConnection(mutableState.value.connection.phase, connection.phase)
            val appliedThrough = publishSnapshot(expectedGeneration, snapshotTicket.token, connection, snapshot)
            if (appliedThrough == null) return@launch
            if (becameOnline) {
                onSuccessfulConnection(pairingGeneration, nowMillis())
            }
            releaseTaskAcknowledgementsThrough(expectedGeneration, appliedThrough)
            markConnectionStable(expectedGeneration)
            acknowledge(expectedGeneration, appliedThrough)
            AppLog.info(
                feature = "connection-runtime",
                message = "fresh companion snapshot applied",
                fields = mapOf(
                    "base_sequence" to snapshot.baseSequence,
                    "project_count" to snapshot.projects.size,
                    "task_count" to snapshot.tasks.size,
                    "output_shape" to "online_launcher_state",
                ),
            )
        }
    }

    @Synchronized
    private fun applyTaskEvent(expectedGeneration: Long, message: ProtocolMessage) {
        if (generation.get() != expectedGeneration) return
        val current = mutableState.value
        if (pendingSnapshotToken != null || current.connection.phase != app.codexlauncher.connection.state.ConnectionPhase.ONLINE) {
            if (pendingTaskEvents.size >= MAX_PENDING_TASK_EVENTS) {
                AppLog.info(
                    feature = "connection-runtime",
                    message = "pending live task event limit reached",
                    fields = mapOf("event_count" to pendingTaskEvents.size, "decision" to "clear_content_and_refresh_snapshot"),
                )
                fail(expectedGeneration, SessionFailure.CONNECTION_LOST)
                return
            }
            pendingTaskEvents.addLast(message)
            AppLog.info(
                feature = "connection-runtime",
                message = "live task event queued until snapshot is ready",
                fields = mapOf(
                    "sequence" to requireNotNull(message.sequence),
                    "event_count" to pendingTaskEvents.size,
                    "output_shape" to "bounded_in_memory_event_queue",
                ),
            )
            return
        }
        val snapshot = current.snapshot
        val updatedTasks = snapshot?.let { TaskEventReducer.apply(it.tasks, message) }
        if (snapshot == null || updatedTasks == null) {
            AppLog.info(
                feature = "connection-runtime",
                message = "live task event could not be applied",
                fields = mapOf(
                    "sequence" to requireNotNull(message.sequence),
                    "decision" to "clear_content_and_refresh_snapshot",
                ),
            )
            fail(expectedGeneration, SessionFailure.CONNECTION_LOST)
            return
        }
        mutableState.value = current.copy(snapshot = snapshot.copy(tasks = updatedTasks))
        val taskId = message.body.getValue("taskId").jsonPrimitive.content
        if (current.transcript?.taskId == taskId) {
            requestTranscriptRefresh(expectedGeneration, taskId, "live_event")
        }
        submissionScope.launch { acknowledge(expectedGeneration, requireNotNull(message.sequence)) }
    }

    @Synchronized
    private fun beginSnapshot(expectedGeneration: Long, baseSequence: Long): SnapshotTicket? {
        if (generation.get() != expectedGeneration) return null
        val isRefresh = mutableState.value.connection.phase == app.codexlauncher.connection.state.ConnectionPhase.ONLINE
        val supersedesSnapshot = pendingSnapshotToken != null
        nextSnapshotToken += 1
        pendingSnapshotToken = nextSnapshotToken
        val removed = pendingTaskEvents.count { requireNotNull(it.sequence) <= baseSequence }
        pendingTaskEvents.removeAll { requireNotNull(it.sequence) <= baseSequence }
        AppLog.info(
            feature = "connection-runtime",
            message = "fresh snapshot became the event ordering barrier",
            fields = mapOf(
                "base_sequence" to baseSequence,
                "snapshot_token" to nextSnapshotToken,
                "covered_event_count" to removed,
                "decision" to "queue_later_events_until_publish",
            ),
        )
        return SnapshotTicket(
            token = nextSnapshotToken,
            isRefresh = isRefresh,
            supersedesSnapshot = supersedesSnapshot,
            retainedProject = publishedProject.get() ?: storedProjectBaseline.get(),
        )
    }

    @Synchronized
    private fun isCurrentSnapshot(expectedGeneration: Long, snapshotToken: Long): Boolean =
        generation.get() == expectedGeneration && pendingSnapshotToken == snapshotToken

    @Synchronized
    private fun retainLoadedProject(
        expectedGeneration: Long,
        snapshotToken: Long,
        loadedProject: ProjectChoice?,
    ): Boolean {
        if (!isCurrentSnapshot(expectedGeneration, snapshotToken)) return false
        if (loadedProject != null) storedProjectBaseline.compareAndSet(null, loadedProject)
        return true
    }

    @Synchronized
    private fun publishSnapshot(
        expectedGeneration: Long,
        snapshotToken: Long,
        connection: ConnectionSnapshot,
        snapshot: ProjectSnapshot,
    ): Long? {
        if (!isCurrentSnapshot(expectedGeneration, snapshotToken)) return null
        var tasks = snapshot.tasks.map { task ->
            if (task.id in mutableState.value.unconfirmedControlTaskIds) task.copy(queueState = TaskQueueState.OUTCOME_UNKNOWN) else task
        }
        var appliedThrough = snapshot.baseSequence
        val queuedEvents = pendingTaskEvents.filter { requireNotNull(it.sequence) > snapshot.baseSequence }
        pendingTaskEvents.clear()
        queuedEvents.forEach { event ->
            tasks =
                TaskEventReducer.apply(tasks, event) ?: run {
                    fail(expectedGeneration, SessionFailure.CONNECTION_LOST)
                    return null
                }
            appliedThrough = maxOf(appliedThrough, requireNotNull(event.sequence))
        }
        pendingSnapshotToken = null
        val selectedProject =
            projectSelection.state.value.selectedProjectId?.let { selectedId ->
                snapshot.projects.singleOrNull { it.id == selectedId }
            }
        publishedProject.set(selectedProject)
        storedProjectBaseline.set(selectedProject)
        val previousTranscript = mutableState.value.transcript
        val nextTranscript =
            previousTranscript?.let { transcript ->
                tasks.singleOrNull { it.id == transcript.taskId }?.let { task -> transcript.copy(title = task.title) }
            }
        val nextFollowUpDraft = nextTranscript?.taskId?.let(followUpDrafts::get).orEmpty()
        mutableState.value =
            LauncherSessionState(
                connection = connection,
                snapshot = snapshot.copy(tasks = tasks),
                transcript = nextTranscript,
                taskManagementAvailable = taskManagementCapable,
                taskControlsAvailable = mutableState.value.taskControlsAvailable,
                newTaskOptions = mutableState.value.newTaskOptions,
                newTaskOptionsSessionId = mutableState.value.newTaskOptionsSessionId,
                newTaskNeedsReview = mutableState.value.newTaskNeedsReview,
                newTaskMessage = mutableState.value.newTaskMessage,
                unconfirmedForkTaskIds = mutableState.value.unconfirmedForkTaskIds,
                unconfirmedControlTaskIds = mutableState.value.unconfirmedControlTaskIds,
                followUpDraft = nextFollowUpDraft,
            )
        openPendingForkIfAvailable()
        AppLog.info(
            feature = "connection-runtime",
            message = "snapshot and queued task events published",
            fields = mapOf(
                "base_sequence" to snapshot.baseSequence,
                "applied_through" to appliedThrough,
                "queued_event_count" to queuedEvents.size,
                "output_shape" to "online_launcher_state",
            ),
        )
        return appliedThrough
    }

    /**
     * Answers a `device_action` the Mac could not carry out itself. The action
     * kind selects the phone-side implementation; that implementation decides
     * the one outcome word that goes back. This layer always answers, including
     * when the attempt throws, because silence costs the user the full timeout.
     */
    private fun handleDeviceAction(expectedGeneration: Long, message: ProtocolMessage) {
        if (generation.get() != expectedGeneration) return
        val requestId = message.body.getValue("requestId").jsonPrimitive.content
        val kind = message.body.getValue("kind").jsonPrimitive.content
        val handle = message.body.getValue("handle").jsonPrimitive.content
        val text = message.body.getValue("text").jsonPrimitive.content

        if (kind == "get_location") {
            submissionScope.launch {
                val payload =
                    try {
                        fetchLocation()
                    } catch (error: Exception) {
                        AppLog.error(
                            feature = "connection-runtime",
                            message = "get_location attempt threw",
                            error = error,
                            fields = mapOf("request_id" to requestId, "decision" to "answer_failed"),
                        )
                        """{"error":"location_unavailable","message":"the location attempt failed unexpectedly"}"""
                    }
                if (payload.contains("\"error\":\"permission_denied\"")) {
                    // DeviceLocationAction is the one place that ever writes this
                    // exact literal into a payload, so a substring check is a safe,
                    // cheap way to notice "go ask the user" without re-parsing JSON
                    // we already validated on the way out.
                    mutableNeedsLocationPermission.value = true
                }
                if (generation.get() != expectedGeneration) return@launch
                sendDeviceActionResult(requestId, "handed_to_the_app", payload)
            }
            return
        }

        val outcome =
            try {
                when (kind) {
                    "notification_reply" -> carryOutDeviceReply(handle, text)
                    "youtube_play" -> carryOutYouTubePlayback(handle)
                    else -> "refused"
                }
            } catch (error: Exception) {
                AppLog.error(
                    feature = "connection-runtime",
                    message = "device action attempt threw",
                    error = error,
                    fields = mapOf("request_id" to requestId, "kind" to kind, "decision" to "answer_failed"),
                )
                "failed"
            }

        if (generation.get() != expectedGeneration) return
        sendDeviceActionResult(requestId, outcome, null)
    }

    private fun sendDeviceActionResult(requestId: String, outcome: String, payload: String?) {
        val encoded =
            buildJsonObject {
                put("version", buildJsonObject { put("major", ProtocolCodec.PROTOCOL_MAJOR); put("minor", 0) })
                put("messageId", UUID.randomUUID().toString())
                put("sender", "phone")
                put("type", "device_action_result")
                put(
                    "body",
                    buildJsonObject {
                        put("requestId", requestId)
                        put("outcome", outcome)
                        if (payload != null) put("payload", payload)
                    },
                )
            }.toString().also(ProtocolCodec::decodeText)
        activeConnection?.sendText(encoded)
    }

    private suspend fun acknowledge(expectedGeneration: Long, throughSequence: Long) {
        acknowledgementMutex.withLock {
            if (generation.get() != expectedGeneration) return
            val request = acknowledgementGate.request(throughSequence) ?: run {
                AppLog.info(
                    feature = "connection-runtime",
                    message = "cumulative acknowledgement deferred",
                    fields = mapOf("requested_sequence" to throughSequence, "decision" to "wait_for_durable_action_result"),
                )
                return
            }
            sendAcknowledgement(expectedGeneration, request)
        }
    }

    private suspend fun sendAcknowledgement(
        expectedGeneration: Long,
        request: AcknowledgementRequest,
    ) {
        if (generation.get() != expectedGeneration) return
        val pairingGeneration = activePairingGeneration
        if (pairingGeneration == null || !recordResumeCursor(pairingGeneration, request.throughSequence)) {
            AppLog.info(
                feature = "connection-runtime",
                message = "resume cursor could not be stored before acknowledgement",
                fields = mapOf(
                    "through_sequence" to request.throughSequence,
                    "decision" to "disconnect_without_acknowledging",
                ),
            )
            fail(expectedGeneration, SessionFailure.CONNECTION_LOST)
            return
        }
        val encoded =
            buildJsonObject {
                put("version", buildJsonObject { put("major", ProtocolCodec.PROTOCOL_MAJOR); put("minor", 0) })
                put("messageId", UUID.randomUUID().toString())
                put("sender", "phone")
                put("type", "ack")
                put("body", buildJsonObject { put("throughSeq", request.throughSequence) })
            }.toString().also(ProtocolCodec::decodeText)
        if (activeConnection?.sendText(encoded) != true) {
            fail(expectedGeneration, SessionFailure.CONNECTION_LOST)
            return
        }
        val acknowledgedActionIds = acknowledgementGate.markSent(request.throughSequence)
        acknowledgedActionIds.forEach { actionId ->
            if (retainedUnknownActionIds.remove(actionId)) {
                AppLog.info(
                    feature = "task-management",
                    message = "uncertain action sequence acknowledged without clearing review gate",
                    fields = mapOf("action_id" to actionId, "decision" to "retain_sent_unknown"),
                )
            } else if (!actionJournal.acknowledge(actionId)) {
                AppLog.info(
                    feature = "connection-runtime",
                    message = "confirmed action metadata cleanup deferred",
                    fields = mapOf("action_id" to actionId, "decision" to "retain_until_expiry"),
                )
            }
        }
        AppLog.info(
            feature = "connection-runtime",
            message = "companion sequence acknowledged",
            fields = mapOf(
                "through_sequence" to request.throughSequence,
                "confirmed_action_count" to acknowledgedActionIds.size,
                "output_shape" to "cumulative_ack",
            ),
        )
    }

    private suspend fun acknowledgeProjectResult() {
        val acknowledgement = pendingProjectAcknowledgement.getAndSet(null) ?: return
        acknowledgementMutex.withLock {
            if (generation.get() != acknowledgement.generation) return
            val request =
                acknowledgementGate.release(acknowledgement.actionId, acknowledgement.sequence)
                    ?: return
            sendAcknowledgement(acknowledgement.generation, request)
        }
    }

    @Synchronized
    private fun taskActionStored(
        expectedGeneration: Long,
        actionId: String,
        sequence: Long,
        requiresSnapshot: Boolean,
        retainUnresolved: Boolean,
    ) {
        if (generation.get() != expectedGeneration) return
        if (retainUnresolved) retainedUnknownActionIds += actionId
        val acknowledgement = TaskAcknowledgement(expectedGeneration, actionId, sequence)
        pendingTaskAcknowledgements[actionId] = acknowledgement
        val publishedThrough = mutableState.value.connection.baseSequence ?: 0L
        if (!requiresSnapshot || publishedThrough > sequence) {
            submissionScope.launch {
                releaseOneTaskAcknowledgement(acknowledgement, maxOf(sequence, publishedThrough))
            }
        }
    }

    private suspend fun releaseOneTaskAcknowledgement(
        acknowledgement: TaskAcknowledgement,
        throughSequence: Long,
    ) {
        acknowledgementMutex.withLock {
            if (generation.get() != acknowledgement.generation ||
                !pendingTaskAcknowledgements.remove(acknowledgement.actionId, acknowledgement)
            ) return
            acknowledgementGate.release(acknowledgement.actionId, acknowledgement.sequence)
            val request = acknowledgementGate.request(throughSequence) ?: return
            sendAcknowledgement(acknowledgement.generation, request)
        }
    }

    private fun releaseTaskAcknowledgementsThrough(expectedGeneration: Long, throughSequence: Long) {
        if (generation.get() != expectedGeneration) return
        pendingTaskAcknowledgements.values
            .filter { it.generation == expectedGeneration && it.sequence < throughSequence }
            .sortedBy { it.sequence }
            .forEach { acknowledgement ->
                if (pendingTaskAcknowledgements.remove(acknowledgement.actionId, acknowledgement)) {
                    acknowledgementGate.release(acknowledgement.actionId, acknowledgement.sequence)
                }
            }
    }

    private suspend fun selectProject(projectId: String): Boolean {
        val request = currentProjectActionRequest() ?: return false
        if (!request.bridge.selectProject(projectId)) return false
        return publishSelectedProject(request.generation, projectId)
    }

    @Synchronized
    private fun currentProjectActionRequest(): ProjectActionRequest? =
        projectBridge?.let { bridge -> ProjectActionRequest(generation.get(), bridge) }

    @Synchronized
    private fun publishSelectedProject(expectedGeneration: Long, projectId: String): Boolean {
        if (generation.get() != expectedGeneration) return false
        val selectedProject = projectSelection.state.value.choices.singleOrNull { it.id == projectId } ?: return false
        publishedProject.set(selectedProject)
        storedProjectBaseline.set(selectedProject)
        mutableState.value = mutableState.value.copy(
            connection = ConnectionStateMachine.reduce(mutableState.value.connection, ConnectionEvent.ProjectSelected(projectId)),
        )
        return true
    }

    @Synchronized
    private fun fail(expectedGeneration: Long, reason: SessionFailure) {
        if (generation.get() != expectedGeneration) return
        generation.incrementAndGet()
        stopTranscriptRefresh("session_failed")
        snapshotScope.cancel()
        snapshotScope = newSnapshotScope()
        projectBridge?.close()
        projectBridge = null
        transcriptCapable = false
        taskManagementCapable = false
        attachmentCapable = false
        decisionCapable = false
        capabilityActionsCapable = false
        maxAttachmentBytes = ProtocolCodec.MAX_ATTACHMENT_BYTES.toLong()
        attachmentUploader.detach()
        taskActionBridge?.close()
        taskActionBridge = null
        taskControlViewModel?.close()
        taskControlViewModel = null
        pendingTaskAcknowledgements.clear()
        retainedUnknownActionIds.clear()
        pendingTranscript = null
        pendingForkTaskId = null
        pendingDecisionRead = null
        decisionViewModel.clear()
        // A lost connection, not a deliberate close: an app action may have
        // already left the phone, so this must not vanish silently the way
        // clear() does. sessionLost() ends it as unverified instead. See
        // closeCurrent() below, which keeps clear() for a real shutdown.
        capabilityController.sessionLost()
        pendingHomePrompt = null
        acknowledgementGate.reset()
        pendingProjectAcknowledgement.set(null)
        pendingTaskEvents.clear()
        pendingSnapshotToken = null
        publishedProject.set(null)
        storedProjectBaseline.set(null)
        activeConnection?.close()
        activeConnection = null
        val event =
            when (reason) {
                SessionFailure.REVOKED -> ConnectionEvent.PairingRevoked
                SessionFailure.INVALID_PROTOCOL -> ConnectionEvent.IncompatibleVersion
                SessionFailure.BOX_UNREACHABLE -> ConnectionEvent.BoxUnreachable
                SessionFailure.CONNECTION_LOST -> ConnectionEvent.ConnectionLost
            }
        mutableState.value = LauncherSessionState(ConnectionStateMachine.reduce(mutableState.value.connection, event))
        AppLog.info(
            feature = "connection-runtime",
            message = "companion session ended",
            fields = mapOf("failure_reason" to reason.name.lowercase(), "output_shape" to "content_cleared"),
        )
        if (reason == SessionFailure.CONNECTION_LOST || reason == SessionFailure.BOX_UNREACHABLE) {
            scheduleRetry()
        } else {
            cancelRetry(resetAttempts = true)
            retryComputer = null
        }
    }

    @Synchronized
    private fun markConnectionStable(expectedGeneration: Long) {
        if (generation.get() != expectedGeneration) return
        cancelRetry(resetAttempts = true)
    }

    private fun scheduleRetry() {
        val paired = retryComputer ?: return
        retryAttempt += 1
        val attempt = retryAttempt
        retryToken += 1
        val token = retryToken
        AppLog.info(
            feature = "connection-runtime",
            message = "automatic companion reconnect scheduled",
            fields = mapOf(
                "attempt" to attempt,
                "backoff_millis" to retryDelayMillis(attempt),
                "decision" to "retry_connection_loss",
            ),
        )
        retryJob = submissionScope.launch {
            retryWait(attempt)
            retryAfterWait(paired, token, attempt)
        }
    }

    @Synchronized
    private fun retryAfterWait(paired: PairedComputer, token: Long, attempt: Int) {
        if (token != retryToken || retryComputer?.deviceId != paired.deviceId) return
        retryJob = null
        AppLog.info(
            feature = "connection-runtime",
            message = "automatic companion reconnect started",
            fields = mapOf("attempt" to attempt, "decision" to "open_fresh_session"),
        )
        startConnection(paired, force = true)
    }

    private fun cancelRetry(resetAttempts: Boolean) {
        retryToken += 1
        retryJob?.cancel()
        retryJob = null
        if (resetAttempts) retryAttempt = 0
    }

    @Synchronized
    private fun closeCurrent(invalidate: Boolean) {
        if (invalidate) generation.incrementAndGet()
        stopTranscriptRefresh("session_closed")
        snapshotScope.cancel()
        snapshotScope = newSnapshotScope()
        projectBridge?.close()
        projectBridge = null
        transcriptCapable = false
        taskManagementCapable = false
        attachmentCapable = false
        decisionCapable = false
        capabilityActionsCapable = false
        maxAttachmentBytes = ProtocolCodec.MAX_ATTACHMENT_BYTES.toLong()
        attachmentUploader.detach()
        taskActionBridge?.close()
        taskActionBridge = null
        taskControlViewModel?.close()
        taskControlViewModel = null
        capabilityController.clear()
        pendingHomePrompt = null
        pendingTaskAcknowledgements.clear()
        retainedUnknownActionIds.clear()
        pendingTranscript = null
        pendingForkTaskId = null
        acknowledgementGate.reset()
        pendingProjectAcknowledgement.set(null)
        pendingTaskEvents.clear()
        pendingSnapshotToken = null
        publishedProject.set(null)
        storedProjectBaseline.set(null)
        activeConnection?.close()
        activeConnection = null
        activeDeviceId = null
    }

    private fun newSnapshotScope(): CoroutineScope =
        CoroutineScope(submissionScope.coroutineContext + SupervisorJob(submissionScope.coroutineContext[Job]))

    override fun onCleared() {
        cancelRetry(resetAttempts = true)
        retryComputer = null
        followUpDrafts.clear()
        attachmentUploader.clearAll()
        closeCurrent(invalidate = true)
        super.onCleared()
    }
}

private fun newTaskMessage(outcome: NewTaskSendOutcome): String? =
    when (outcome) {
        NewTaskSendOutcome.Complete -> null
        NewTaskSendOutcome.CompleteDraftRetained -> "Task started, but the saved draft could not be cleared."
        NewTaskSendOutcome.Invalid -> "This prompt or task setup is no longer valid. Review the task options and try again."
        NewTaskSendOutcome.Unavailable -> "Could not send. Your draft is still here. Check the connection and try again."
        NewTaskSendOutcome.NeedsReview -> null
        is NewTaskSendOutcome.Failed -> "The computer could not start this task. Your draft is still here. Try again."
    }

private data class ProjectAcknowledgement(
    val generation: Long,
    val actionId: String,
    val sequence: Long,
)

private data class TaskAcknowledgement(
    val generation: Long,
    val actionId: String,
    val sequence: Long,
)

private data class TaskActionRequest(
    val generation: Long,
    val bridge: TaskActionBridge,
)

private data class PendingTranscriptRequest(
    val generation: Long,
    val requestId: String,
    val taskId: String,
    val mode: TranscriptReadMode,
)

private data class PendingHomePrompt(
    val prompt: String,
    val selection: NewTaskSelection?,
    val draftVersion: DraftVersion,
)

private enum class TranscriptReadMode { INITIAL, EARLIER, REFRESH }

internal const val TRANSCRIPT_REFRESH_MILLIS = 2_000L

private fun mergeRefreshedEntries(current: List<TranscriptEntry>, refreshed: List<TranscriptEntry>): List<TranscriptEntry> {
    val refreshedById = refreshed.associateBy(TranscriptEntry::id)
    val currentIds = current.mapTo(mutableSetOf(), TranscriptEntry::id)
    return current.map { refreshedById[it.id] ?: it } + refreshed.filterNot { it.id in currentIds }
}

private data class PendingDecisionRequest(
    val generation: Long,
    val requestId: String,
    val taskId: String,
)

private data class ProjectActionRequest(
    val generation: Long,
    val bridge: ProjectSessionBridge,
)

private data class SnapshotTicket(
    val token: Long,
    val isRefresh: Boolean,
    val supersedesSnapshot: Boolean,
    val retainedProject: ProjectChoice?,
)

private const val MAX_PENDING_TASK_EVENTS = 128
private const val TRANSCRIPT_PAGE_SIZE = 32

internal fun retryDelayMillis(attempt: Int): Long {
    val exponent = (attempt - 1).coerceIn(0, 5)
    return minOf(30_000L, 1_000L * (1L shl exponent))
}
