package app.codexlauncher

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import android.os.Bundle
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.BackHandler
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.codexlauncher.appearance.theme.AppearanceMode
import app.codexlauncher.appearance.theme.QuietInstrumentTheme
import app.codexlauncher.appearance.theme.ThemePreferenceStore
import app.codexlauncher.appearance.theme.themeDataStore
import app.codexlauncher.appearance.settings.AppearanceScreen
import app.codexlauncher.capability.reply.guard.ThreadKey
import app.codexlauncher.connection.pairing.PairingScreen
import app.codexlauncher.connection.pairing.PairingViewModel
import app.codexlauncher.connection.pairing.network.AndroidDevicePairingSigner
import app.codexlauncher.connection.pairing.network.PairingClient
import app.codexlauncher.connection.pairing.network.PairedComputer
import app.codexlauncher.connection.pairing.network.PinnedPairingTransport
import app.codexlauncher.connection.lifecycle.PairingConnectionCommand
import app.codexlauncher.connection.lifecycle.pairingConnectionCommand
import app.codexlauncher.connection.runtime.LauncherSessionViewModel
import app.codexlauncher.connection.state.ConnectionPhase
import app.codexlauncher.connection.stream.CodexConnectionService
import app.codexlauncher.connection.stream.userWarning
import app.codexlauncher.diagnostics.AppLog
import app.codexlauncher.task.thread.TaskThreadAssembler
import app.codexlauncher.task.thread.ThreadAskPolicy
import app.codexlauncher.task.thread.TypedTextRoute
import app.codexlauncher.launcher.apps.AppDrawerScreen
import app.codexlauncher.launcher.apps.InstalledApp
import app.codexlauncher.launcher.apps.InstalledAppsLoader
import app.codexlauncher.launcher.apps.InstalledAppsRepository
import app.codexlauncher.launcher.home.HomeScreen
import kotlinx.coroutines.isActive
import kotlinx.coroutines.delay
import app.codexlauncher.runtime.standalone.LocalRuntimeEndpoint
import app.codexlauncher.runtime.standalone.StandaloneRuntimeStatusReader
import app.codexlauncher.runtime.standalone.StandaloneRuntimeStatus
import app.codexlauncher.runtime.localpair.bootstrap.LocalPairLoopbackBootstrap
import app.codexlauncher.launcher.home.HomeSendRouter
import app.codexlauncher.launcher.home.HomeSendDecision
import app.codexlauncher.capability.interaction.PromptDestination
import app.codexlauncher.launcher.home.HomeUiPolicy
import app.codexlauncher.launcher.home.lastConnectedLabel
import app.codexlauncher.launcher.home.sortedForHome
import app.codexlauncher.launcher.home.toHomeTask
import app.codexlauncher.launcher.surface.AttachmentChoiceDialog
import app.codexlauncher.launcher.surface.BackgroundConnectionWarningDialog
import app.codexlauncher.launcher.surface.LauncherLoadingScreen
import app.codexlauncher.launcher.surface.LocalStateRecoveryScreen
import app.codexlauncher.launcher.surface.NotificationAccessDialog
import app.codexlauncher.launcher.surface.ReplyStopOfferRow
import app.codexlauncher.launcher.surface.UnpairConfirmationDialog
import app.codexlauncher.project.selection.ProjectSelector
import app.codexlauncher.project.selection.ProjectSelectionUiState
import app.codexlauncher.storage.pairing.PairingRecordReadState
import app.codexlauncher.storage.wipe.LocalStateWriteResult
import app.codexlauncher.storage.wipe.StartupRecovery
import app.codexlauncher.storage.wipe.WipeResult
import app.codexlauncher.task.transcript.TaskScreen
import app.codexlauncher.task.transcript.TranscriptDetail
import app.codexlauncher.task.transcript.TranscriptDetailScreen
import app.codexlauncher.task.composer.DraftComposerViewModel
import app.codexlauncher.task.dictation.OnDevicePromptDictation
import app.codexlauncher.task.attachments.AttachmentDocumentReader
import app.codexlauncher.task.attachments.AttachmentSelection
import androidx.activity.result.PickVisualMediaRequest
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import app.codexlauncher.updater.AlphaReleaseCandidate
import app.codexlauncher.updater.GitHubAlphaFeed
import app.codexlauncher.updater.UpdateCheckResult
import app.codexlauncher.updater.UpdateChecker
import app.codexlauncher.updater.UpdatePipeline
import app.codexlauncher.updater.install.ApkUpdateInstaller
import app.codexlauncher.updater.ui.UpdateAvailableDialog
import kotlinx.coroutines.withContext

class LauncherActivity : ComponentActivity() {
    private val themePreferences by lazy { ThemePreferenceStore(applicationContext.themeDataStore) }
    private val launcherApplication get() = application as LauncherApplication
    private val localState get() = launcherApplication.localState
    private val pairingViewModel: PairingViewModel by viewModels {
        viewModelFactory { initializer { createPairingViewModel() } }
    }
    private val draftComposerViewModel: DraftComposerViewModel get() = launcherApplication.draftComposer
    private val sessionViewModel: LauncherSessionViewModel get() = launcherApplication.session

    private fun createPairingViewModel(): PairingViewModel {
        val client = PairingClient(AndroidDevicePairingSigner(localState.pairingKeys), PinnedPairingTransport())
        return PairingViewModel(
            pair = { encoded, deviceId, deviceName ->
                when (val result = localState.gate.withPairingWrite { client.pair(encoded, deviceId, deviceName) }) {
                    is LocalStateWriteResult.Completed -> result.value
                    LocalStateWriteResult.Blocked -> throw IllegalStateException("Pairing is unavailable while local state is being recovered")
                }
            },
            save = localState.pairingRecords::save,
            deviceId = {
                when (val result = localState.gate.withPairingWrite(localState.deviceIdentity::loadOrCreate)) {
                    is LocalStateWriteResult.Completed -> result.value
                    LocalStateWriteResult.Blocked -> throw IllegalStateException("Pairing is unavailable while local state is being recovered")
                }
            },
            deviceName = Build.MODEL.ifBlank { "Android device" },
        )
    }

    private var homeIntentSequence by mutableLongStateOf(0L)

    private val updatePipeline by lazy {
        UpdatePipeline(
            feed = GitHubAlphaFeed(),
            installedVersionCode = {
                packageManager.getPackageInfo(packageName, 0).longVersionCode.toInt()
            },
        )
    }
    private val apkUpdateInstaller by lazy { ApkUpdateInstaller(this) }

    private fun isNetworkUnmetered(): Boolean {
        val connectivity = getSystemService(ConnectivityManager::class.java) ?: return false
        val network = connectivity.activeNetwork ?: return false
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLog.info(
            feature = "launcher",
            message = "activity created",
            fields = mapOf("input_shape" to "saved_state=${savedInstanceState != null}"),
        )
        setContent {
            val appearanceMode by themePreferences.mode.collectAsState(initial = AppearanceMode.FOLLOW_SYSTEM)
            val pairingUiState by pairingViewModel.state.collectAsState()
            val sessionUiState by sessionViewModel.state.collectAsState()
            val draftComposerState by draftComposerViewModel.state.collectAsState()
            val attachmentUploads by sessionViewModel.attachments.collectAsState()
            val decisionState by sessionViewModel.decisions.collectAsState()
            val capabilityState by sessionViewModel.capabilityInteraction.collectAsState()
            val projectUiState by sessionViewModel.projectSelection.state.collectAsState()
            val notificationAccessBlock by launcherApplication.notificationAccessAsk.state.collectAsState()
            val lastRepliedConversation by launcherApplication.replyGuard.lastReplied.collectAsState()
            val scope = rememberCoroutineScope()
            val dictation = remember { OnDevicePromptDictation(applicationContext, scope) }
            val dictationState by dictation.state.collectAsState()
            var availableUpdate by remember { mutableStateOf<AlphaReleaseCandidate?>(null) }
            var updateBusy by remember { mutableStateOf(false) }
            var updateStatusMessage by remember { mutableStateOf<String?>(null) }

            fun installAvailableUpdate() {
                val candidate = availableUpdate ?: return
                scope.launch {
                    updateBusy = true
                    updateStatusMessage = "Downloading…"
                    runCatching {
                        dictation.cancelAndWait()
                        if (!packageManager.canRequestPackageInstalls()) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                            updateStatusMessage = "Allow installs from this app, then try again."
                            return@runCatching
                        }
                        val apk =
                            withContext(Dispatchers.IO) {
                                apkUpdateInstaller.downloadAndVerify(candidate)
                            }
                        updateStatusMessage = "Starting installer…"
                        withContext(Dispatchers.IO) { apkUpdateInstaller.installApk(apk) }
                    }.onFailure { error ->
                        AppLog.error(feature = "updater", message = "update install failed", error = error)
                        updateStatusMessage = "Update failed. Try again."
                    }
                    updateBusy = false
                }
            }
            fun runUpdateCheck(manual: Boolean) {
                scope.launch {
                    updateBusy = true
                    updateStatusMessage = if (manual) "Checking…" else updateStatusMessage
                    val outcome =
                        withContext(Dispatchers.IO) { updatePipeline.checkForUpdate() }
                    when (outcome) {
                        UpdateCheckResult.Unavailable -> {
                            updateStatusMessage =
                                if (manual) "Couldn’t check for updates. Try again." else null
                            availableUpdate = null
                            updateBusy = false
                            return@launch
                        }
                        UpdateCheckResult.UpToDate -> {
                            updateStatusMessage = if (manual) "You’re on the latest alpha." else null
                            availableUpdate = null
                            updateBusy = false
                            return@launch
                        }
                        is UpdateCheckResult.Available -> {
                            val candidate = outcome.candidate
                            availableUpdate = candidate
                            updateStatusMessage = "Update alpha-${candidate.versionCode} available"
                            val mayDownload =
                                UpdateChecker.shouldAutoDownload(
                                    networkUnmetered = isNetworkUnmetered(),
                                    manualRequest = manual,
                                )
                            updateBusy = false
                            if (mayDownload) {
                                installAvailableUpdate()
                            } else {
                                updateStatusMessage = "Update available. Connect to Wi‑Fi or tap Install."
                            }
                        }
                    }
                }
            }

            LaunchedEffect(Unit) {
                // Defer the update check off the cold-launch / first-connect /
                // first-send window. It runs on IO and never blocked connect, but
                // it fires a synchronous GitHub releases fetch at the exact moment
                // the companion socket is coming up and the user may tap Send, so
                // it contended for the radio and OkHttp dispatcher during the part
                // of startup that must feel instant. Manual "check for updates"
                // (runUpdateCheck) stays immediate; only this automatic boot check waits.
                delay(6_000)
                withContext(Dispatchers.IO) {
                    apkUpdateInstaller.clearStaleCache()
                    val outcome = updatePipeline.checkForUpdate()
                    val candidate =
                        (outcome as? UpdateCheckResult.Available)?.candidate ?: return@withContext
                    withContext(Dispatchers.Main) {
                        availableUpdate = candidate
                        updateStatusMessage = "Update alpha-${candidate.versionCode} available"
                    }
                    val unmetered = isNetworkUnmetered()
                    if (!UpdateChecker.shouldAutoDownload(networkUnmetered = unmetered, manualRequest = false)) {
                        AppLog.info(
                            feature = "updater",
                            message = "update available but auto-download skipped on metered network",
                            fields = mapOf("version_code" to candidate.versionCode),
                        )
                        return@withContext
                    }
                    AppLog.info(
                        feature = "updater",
                        message = "auto-download on unmetered network",
                        fields = mapOf("version_code" to candidate.versionCode),
                    )
                    withContext(Dispatchers.Main) { installAvailableUpdate() }
                }
            }
            val appsRepository = remember { InstalledAppsRepository(applicationContext) }
            val appsLoader = remember { InstalledAppsLoader(appsRepository) }
            var pairingState by remember { mutableStateOf<PairingRecordState>(PairingRecordState.Loading) }
            var localStorageUiState by remember { mutableStateOf(LocalStorageUiState.RECOVERING) }
            var recoveryAttempt by remember { mutableLongStateOf(0L) }
            var destination by rememberSaveable { mutableStateOf(LauncherDestination.HOME) }
            var installedApps by remember { mutableStateOf(emptyList<InstalledApp>()) }
            var connectionHelpVisible by rememberSaveable { mutableStateOf(false) }
            var connectionServiceWarning by rememberSaveable { mutableStateOf<String?>(null) }
            var appLaunchFailureMessage by rememberSaveable { mutableStateOf<String?>(null) }
            var unpairConfirmVisible by rememberSaveable { mutableStateOf(false) }
            var transcriptDetail by remember { mutableStateOf<TranscriptDetail?>(null) }
            var attachmentChoiceVisible by rememberSaveable { mutableStateOf(false) }
            var attachmentMessage by remember { mutableStateOf<String?>(null) }
            var stoppedConversations by remember { mutableStateOf(emptyList<ThreadKey>()) }
            DisposableEffect(dictation) {
                onDispose { dictation.close() }
            }
            LaunchedEffect(destination) {
                dictation.cancel()
            }
            val attachmentReader = remember { AttachmentDocumentReader(contentResolver) }
            val acceptPickedAttachment: (Uri?) -> Unit = { uri ->
                if (uri != null) {
                    scope.launch {
                        val limit = sessionViewModel.attachmentLimitBytes()
                        val picked = withContext(Dispatchers.IO) { attachmentReader.read(uri, limit) }
                        attachmentMessage =
                            if (picked == null) {
                                "Could not attach that file. It may be too large or unavailable."
                            } else {
                                val result = sessionViewModel.addAttachment(picked.displayName, picked.mediaType, picked.bytes)
                                picked.bytes.fill(0)
                                when (result) {
                                    is AttachmentSelection.Accepted -> null
                                    AttachmentSelection.TooLarge -> "That file is too large."
                                    AttachmentSelection.TooMany -> "You can attach up to two files."
                                    AttachmentSelection.UnsupportedType -> "Audio and video files are not supported."
                                    AttachmentSelection.Invalid -> "That file cannot be attached."
                                }
                            }
                    }
                }
            }
            val photoPicker =
                rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia(), acceptPickedAttachment)
            val documentPicker =
                rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument(), acceptPickedAttachment)
            var cameraPermissionGranted by remember {
                mutableStateOf(
                    ContextCompat.checkSelfPermission(applicationContext, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED,
                )
            }
            val cameraPermission =
                rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
                    cameraPermissionGranted = granted
                }
            val notificationPermission =
                rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
                    AppLog.info(
                        feature = "connection-service",
                        message = "notification permission request finished",
                        fields = mapOf("output_shape" to "granted=$granted"),
                    )
                }
            val locationPermission =
                rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
                    AppLog.info(
                        feature = "connection-runtime",
                        message = "location permission request finished",
                        fields = mapOf("output_shape" to "granted=$granted"),
                    )
                }
            val needsLocationPermission by sessionViewModel.needsLocationPermission.collectAsState()
            LaunchedEffect(needsLocationPermission) {
                if (needsLocationPermission) {
                    locationPermission.launch(Manifest.permission.ACCESS_FINE_LOCATION)
                    sessionViewModel.consumeLocationPermissionRequest()
                }
            }
            LaunchedEffect(recoveryAttempt) {
                localStorageUiState = LocalStorageUiState.RECOVERING
                pairingState = PairingRecordState.Loading
                when (
                    localState.wiper.recover {
                        when (val stored = localState.pairingRecords.readForStartup()) {
                            is PairingRecordReadState.Paired -> true
                            PairingRecordReadState.Unpaired -> false
                            PairingRecordReadState.Unavailable -> throw IllegalStateException("Pairing storage is unavailable")
                        }
                    }
                ) {
                    StartupRecovery.Paired,
                    StartupRecovery.Unpaired,
                    -> {
                        localStorageUiState = LocalStorageUiState.READY
                        localState.pairingRecords.paired.collect { paired ->
                            if (localStorageUiState == LocalStorageUiState.READY) {
                                pairingState = PairingRecordState.Loaded(paired)
                            }
                        }
                    }
                    StartupRecovery.StorageUnavailable -> {
                        localStorageUiState = LocalStorageUiState.FAILED
                        pairingState = PairingRecordState.RecoveryFailed
                    }
                }
            }
            val removeLocalData: () -> Unit = {
                sessionViewModel.clearFollowUpDrafts()
                sessionViewModel.disconnect()
                CodexConnectionService.stop(applicationContext)
                sessionViewModel.closeTask()
                transcriptDetail = null
                localStorageUiState = LocalStorageUiState.WIPING
                pairingState = PairingRecordState.Loading
                scope.launch {
                    when (localState.wiper.wipe()) {
                        WipeResult.Complete -> {
                            pairingViewModel.resetAfterUnpair()
                            localStorageUiState = LocalStorageUiState.READY
                            pairingState = PairingRecordState.Loaded(null)
                            destination = LauncherDestination.HOME
                        }
                        WipeResult.AlreadyInProgress,
                        is WipeResult.Incomplete,
                        -> {
                            localStorageUiState = LocalStorageUiState.FAILED
                            pairingState = PairingRecordState.RecoveryFailed
                        }
                    }
                }
            }
            val pairedComputer = (pairingState as? PairingRecordState.Loaded)?.record
            val lastConnectionEpoch by
                remember(pairedComputer?.pairingGeneration) {
                    localState.lastConnections.forPairing(pairedComputer?.pairingGeneration)
                }.collectAsState(initial = null)
            var standaloneStatus by remember {
                mutableStateOf(StandaloneRuntimeStatus.notReady())
            }
            var homeRouteMessage by remember { mutableStateOf<String?>(null) }
            var localAutoLinkBusy by remember { mutableStateOf(false) }
            var localAutoLinkAttempted by rememberSaveable { mutableStateOf(false) }
            // Callers: Home Compose status strip. Blocking socket probe → readOffMain (IO).
            // User: "Fix: Run probe on Dispatchers.IO" + unpaired loopback session connect.
            LaunchedEffect(localStorageUiState, pairingState) {
                if (localStorageUiState != LocalStorageUiState.READY) return@LaunchedEffect
                while (isActive) {
                    standaloneStatus = StandaloneRuntimeStatusReader.readOffMain(applicationContext)
                    delay(2_000)
                }
            }
            suspend fun runSilentLocalLink(from: String): LocalPairLoopbackBootstrap.Outcome {
                localAutoLinkBusy = true
                return try {
                    AppLog.info(
                        feature = "standalone",
                        message = "silent local-pair bootstrap starting",
                        fields = mapOf("from" to from),
                    )
                    val outcome =
                        withContext(Dispatchers.IO) {
                            LocalPairLoopbackBootstrap.run(applicationContext)
                        }
                    AppLog.info(
                        feature = "standalone",
                        message = "silent local-pair bootstrap finished",
                        fields =
                            mapOf(
                                "from" to from,
                                "outcome" to
                                    when (outcome) {
                                        LocalPairLoopbackBootstrap.Outcome.AlreadyReady -> "already_ready"
                                        LocalPairLoopbackBootstrap.Outcome.NotReachable -> "not_reachable"
                                        is LocalPairLoopbackBootstrap.Outcome.Linked -> "linked"
                                        is LocalPairLoopbackBootstrap.Outcome.Failed -> "failed"
                                    },
                            ),
                    )
                    when (outcome) {
                        LocalPairLoopbackBootstrap.Outcome.AlreadyReady,
                        is LocalPairLoopbackBootstrap.Outcome.Linked,
                        -> {
                            standaloneStatus = StandaloneRuntimeStatusReader.readOffMain(applicationContext)
                            // Unpaired Mac path: open the loopback session. When a Mac is
                            // already paired, leave that session alone — LocalRuntimeEndpoint
                            // is still saved for on-phone capability routing.
                            if (pairedComputer == null) {
                                LocalRuntimeEndpoint.load(applicationContext)?.let { endpoint ->
                                    sessionViewModel.connect(endpoint)
                                }
                            }
                            homeRouteMessage = null
                        }
                        LocalPairLoopbackBootstrap.Outcome.NotReachable -> {
                            if (from != "auto") {
                                homeRouteMessage = "Local runtime is unreachable"
                            }
                        }
                        is LocalPairLoopbackBootstrap.Outcome.Failed -> {
                            homeRouteMessage = "Couldn’t link local runtime (${outcome.error})"
                        }
                    }
                    outcome
                } finally {
                    localAutoLinkBusy = false
                }
            }
            // Silent auto-link when runtime reachable + Android prefs missing ack.
            // Runs whether or not a Mac is paired — local-pair is independent.
            // Never opens Termux / LocalPairAwaitActivity on this path.
            LaunchedEffect(
                localStorageUiState,
                pairingState,
                standaloneStatus.reachable,
                standaloneStatus.localPairAcked,
            ) {
                if (localStorageUiState != LocalStorageUiState.READY) return@LaunchedEffect
                if (standaloneStatus.localPairAcked) return@LaunchedEffect
                if (!standaloneStatus.reachable) return@LaunchedEffect
                if (localAutoLinkAttempted || localAutoLinkBusy) return@LaunchedEffect
                localAutoLinkAttempted = true
                val outcome = runSilentLocalLink("auto")
                if (outcome is LocalPairLoopbackBootstrap.Outcome.NotReachable) {
                    localAutoLinkAttempted = false
                }
            }
            LaunchedEffect(localStorageUiState, pairingState, standaloneStatus.localPairAcked) {
                if (localStorageUiState != LocalStorageUiState.READY) return@LaunchedEffect
                if (pairedComputer != null) return@LaunchedEffect
                val localEndpoint = LocalRuntimeEndpoint.load(applicationContext) ?: return@LaunchedEffect
                if (!standaloneStatus.localPairAcked) return@LaunchedEffect
                AppLog.info(
                    feature = "standalone",
                    message = "connecting unpaired local phone-runtime session",
                    fields =
                        mapOf(
                            "device_id" to localEndpoint.deviceId,
                            "host" to localEndpoint.host,
                            "port" to localEndpoint.port,
                        ),
                )
                sessionViewModel.connect(localEndpoint)
            }
            LaunchedEffect(localStorageUiState, pairedComputer?.pairingGeneration) {
                if (localStorageUiState != LocalStorageUiState.READY) return@LaunchedEffect
                if (pairedComputer == null) {
                    draftComposerViewModel.load("standalone")
                    AppLog.info(
                        feature = "standalone",
                        message = "loaded standalone draft owner",
                        fields = mapOf("owner" to "standalone"),
                    )
                }
            }
            val loadedRootDestination = pairingState.startDestination()
            val rootDestination = loadedRootDestination ?: LauncherDestination.HOME
            val visibleDestination =
                loadedRootDestination?.let {
                    visibleDestination(
                        root = it,
                        requested = destination,
                        phase = sessionUiState.connection.phase,
                        hasTranscript = sessionUiState.transcript != null,
                        hasDetail = transcriptDetail != null,
                    )
                }
            LaunchedEffect(pairingState) {
                when {
                    pairedComputer != null && destination == LauncherDestination.PAIRING -> destination = LauncherDestination.HOME
                }
                when (pairingConnectionCommand(pairingState)) {
                    PairingConnectionCommand.KEEP -> Unit
                    PairingConnectionCommand.DISCONNECT -> {
                        draftComposerViewModel.reset()
                        sessionViewModel.disconnect()
                        CodexConnectionService.stop(applicationContext)
                    }
                    PairingConnectionCommand.CONNECT ->
                        pairedComputer?.let { paired ->
                            draftComposerViewModel.load(paired.pairingGeneration)
                            sessionViewModel.connect(paired)
                            val startResult = CodexConnectionService.start(this@LauncherActivity)
                            connectionServiceWarning = startResult.userWarning()
                            AppLog.info(
                                feature = "connection-service",
                                message = "visible launcher requested connection service",
                                fields = mapOf("output_shape" to "start_result=${startResult.name.lowercase()}"),
                            )
                            if (
                                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                                ContextCompat.checkSelfPermission(applicationContext, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                            ) {
                                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                            }
                        }
                }
            }
            LaunchedEffect(destination, sessionUiState.connection.phase, sessionUiState.transcript?.taskId) {
                if (destination == LauncherDestination.PROJECT && sessionUiState.connection.phase != ConnectionPhase.ONLINE) {
                    destination = LauncherDestination.HOME
                }
                if (destination == LauncherDestination.TASK &&
                    (sessionUiState.connection.phase != ConnectionPhase.ONLINE || sessionUiState.transcript == null)
                ) {
                    sessionViewModel.closeTask()
                    transcriptDetail = null
                    destination = LauncherDestination.HOME
                }
                if (destination == LauncherDestination.TASK_DETAIL &&
                    (sessionUiState.connection.phase != ConnectionPhase.ONLINE || sessionUiState.transcript == null || transcriptDetail == null)
                ) {
                    transcriptDetail = null
                    destination = if (sessionUiState.transcript == null) LauncherDestination.HOME else LauncherDestination.TASK
                }
            }
            val currentHomeIntentSequence = homeIntentSequence
            LaunchedEffect(currentHomeIntentSequence, pairingState) {
                if (pairingState is PairingRecordState.Loaded) {
                    sessionViewModel.clearAttachments()
                    sessionViewModel.closeTask()
                    transcriptDetail = null
                    destination = LauncherDestination.HOME
                }
                connectionHelpVisible = false
            }
            LaunchedEffect(destination) {
                if (destination == LauncherDestination.APPS) {
                    installedApps = appsLoader.load()
                }
                if (destination == LauncherDestination.APPEARANCE) {
                    stoppedConversations = launcherApplication.durableStops.stopped().toList()
                }
            }
            DisposableEffect(decisionState.active?.requestId) {
                if (decisionState.active != null) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
            }
            BackHandler(enabled = destination in setOf(LauncherDestination.APPS, LauncherDestination.APPEARANCE, LauncherDestination.PROJECT, LauncherDestination.TASK, LauncherDestination.TASK_DETAIL, LauncherDestination.PAIRING)) {
                val from = destination
                destination =
                    when (destination) {
                        LauncherDestination.APPEARANCE -> LauncherDestination.APPS
                        LauncherDestination.PROJECT -> LauncherDestination.HOME
                        LauncherDestination.PAIRING -> LauncherDestination.HOME
                        LauncherDestination.TASK -> {
                            sessionViewModel.clearAttachments()
                            sessionViewModel.closeTask()
                            transcriptDetail = null
                            LauncherDestination.HOME
                        }
                        LauncherDestination.TASK_DETAIL -> {
                            transcriptDetail = null
                            LauncherDestination.TASK
                        }
                        LauncherDestination.APPS -> rootDestination
                        LauncherDestination.HOME -> destination
                    }
                if (from == LauncherDestination.PAIRING) {
                    scope.launch { localState.gate.abortPairing() }
                }
            }
            QuietInstrumentTheme(mode = appearanceMode) {
                if (pairingState == PairingRecordState.RecoveryFailed && destination !in setOf(LauncherDestination.APPS, LauncherDestination.APPEARANCE)) {
                    LocalStateRecoveryScreen(
                        onRetry = { recoveryAttempt += 1 },
                        onRemoveLocalData = removeLocalData,
                        onAllApps = { destination = LauncherDestination.APPS },
                        onAndroidSettings = ::openAndroidSettings,
                    )
                } else if (visibleDestination == null && destination !in setOf(LauncherDestination.APPS, LauncherDestination.APPEARANCE)) {
                    LauncherLoadingScreen()
                } else when (visibleDestination ?: destination) {
                    LauncherDestination.PAIRING ->
                        PairingScreen(
                            state = pairingUiState,
                            cameraPermissionGranted = cameraPermissionGranted,
                            onRequestCameraPermission = { cameraPermission.launch(Manifest.permission.CAMERA) },
                            onShowScanner = pairingViewModel::showScanner,
                            onShowManualEntry = pairingViewModel::showManualEntry,
                            onManualEntryChanged = pairingViewModel::updateManualEntry,
                            onSubmitManual = pairingViewModel::submitManualEntry,
                            onQrDecoded = pairingViewModel::submitScanned,
                            onRetrySave = pairingViewModel::submitSaveRetry,
                            onAllApps = { destination = LauncherDestination.APPS },
                            onAndroidSettings = ::openAndroidSettings,
                        )
                    LauncherDestination.HOME ->
                        HomeScreen(
                            state =
                                HomeUiPolicy.render(
                                    computerName = sessionUiState.snapshot?.computerName ?: "Paired computer",
                                    connection = sessionUiState.connection,
                                    projects = sessionUiState.snapshot?.projects ?: emptyList(),
                                    tasks = sessionUiState.snapshot?.tasks?.sortedForHome()?.map { it.toHomeTask() } ?: emptyList(),
                                    lastConnectedLabel = lastConnectionEpoch?.let { lastConnectedLabel(applicationContext, it) },
                                    standalone = standaloneStatus,
                                    promptDestination = capabilityState.destination,
                                    paired = pairedComputer != null,
                                ).let { rendered ->
                                    if (localAutoLinkBusy) {
                                        rendered.copy(showLinkLocalRuntime = false)
                                    } else {
                                        rendered
                                    }
                                },
                            newTaskOptions = sessionUiState.newTaskOptions,
                            newTaskOptionsKey = sessionUiState.newTaskOptionsSessionId,
                            composerState = draftComposerState,
                            onPromptChange = { text ->
                                homeRouteMessage = null
                                draftComposerViewModel.update(text)
                            },
                            onSend = { prompt, selection ->
                                val version = draftComposerState.version ?: return@HomeScreen
                                val macOnlineWithProject =
                                    sessionUiState.connection.phase == ConnectionPhase.ONLINE &&
                                        !sessionUiState.connection.selectedProjectId.isNullOrBlank() &&
                                        sessionUiState.connection.baseSequence != null &&
                                        sessionUiState.connection.baseSequence!! > 0
                                val decision =
                                    HomeSendRouter.decide(
                                        destination = capabilityState.destination,
                                        standalone = standaloneStatus,
                                        macOnlineWithProject = macOnlineWithProject,
                                        macPaired = pairedComputer != null,
                                    )
                                AppLog.info(
                                    feature = "standalone",
                                    message = "home send routed",
                                    fields =
                                        mapOf(
                                            "decision" to decision.name.lowercase(),
                                            "destination" to capabilityState.destination.name.lowercase(),
                                            "standalone_ready" to standaloneStatus.isReady,
                                            "mac_online_with_project" to macOnlineWithProject,
                                        ),
                                )
                                when (decision) {
                                    HomeSendDecision.CapabilityOnPhone -> {
                                        homeRouteMessage = null
                                        scope.launch {
                                            // AUTO + standalone-ready must use loopback phone-runtime
                                            // even when a Mac pairing record exists (Mac may be offline
                                            // and holding activeConnection). HomeSendRouter already
                                            // chose CapabilityOnPhone; open the local sink first — but
                                            // only when the socket isn't already warm to it. Forcing a
                                            // reconnect on every send tore down and rebuilt the socket
                                            // (fresh TLS + full snapshot re-sync) each time, adding
                                            // seconds of dead-wait before the prompt left; the force is
                                            // only needed when the active connection is a different
                                            // (possibly offline) endpoint.
                                            val local = LocalRuntimeEndpoint.load(applicationContext)
                                            if (local != null && !sessionViewModel.isOnlineTo(local.deviceId)) {
                                                sessionViewModel.connect(local, force = true)
                                                var online = false
                                                repeat(50) {
                                                    if (sessionViewModel.state.value.connection.phase ==
                                                        ConnectionPhase.ONLINE
                                                    ) {
                                                        online = true
                                                        return@repeat
                                                    }
                                                    delay(100)
                                                }
                                                if (!online) {
                                                    homeRouteMessage = "Codex services unavailable."
                                                    return@launch
                                                }
                                            }
                                            sessionViewModel.submitHomePrompt(
                                                prompt = prompt,
                                                selection = selection,
                                                draftVersion = version,
                                                forceCapability = true,
                                            )
                                        }
                                    }
                                    HomeSendDecision.StartComputerTask -> {
                                        if (selection == null) {
                                            homeRouteMessage = "Choose model options before sending to the computer"
                                            return@HomeScreen
                                        }
                                        homeRouteMessage = null
                                        scope.launch {
                                            sessionViewModel.submitHomePrompt(prompt, selection, version)
                                        }
                                    }
                                    HomeSendDecision.LinkLocalRuntime -> {
                                        // Silent loopback bootstrap — never Termux / AwaitActivity.
                                        scope.launch {
                                            localAutoLinkAttempted = true
                                            runSilentLocalLink("send")
                                        }
                                    }
                                    HomeSendDecision.OpenPairing -> {
                                        homeRouteMessage = null
                                        scope.launch {
                                            localState.gate.beginPairing()
                                            destination = LauncherDestination.PAIRING
                                        }
                                    }
                                    HomeSendDecision.ComputerOffline -> {
                                        homeRouteMessage = "Computer offline"
                                    }
                                }
                            },
                            promptDestination = capabilityState.destination,
                            capabilityBusy = capabilityState.busy,
                            capabilityMessage = capabilityState.message ?: homeRouteMessage,
                            onPromptDestinationChange = sessionViewModel::setPromptDestination,
                            newTaskNeedsReview = sessionUiState.newTaskNeedsReview,
                            newTaskMessage = sessionUiState.newTaskMessage,
                            onDismissNewTaskReview = {
                                scope.launch { sessionViewModel.dismissUnconfirmedNewTask() }
                            },
                            attachments = attachmentUploads,
                            attachmentMessage = attachmentMessage,
                            onRemoveAttachment = { uploadId ->
                                sessionViewModel.removeAttachment(uploadId)
                                attachmentMessage = null
                            },
                            onAttach = { attachmentChoiceVisible = true },
                            dictationState = dictationState,
                            onLinkComputer = {
                                scope.launch {
                                    localState.gate.beginPairing()
                                    destination = LauncherDestination.PAIRING
                                    AppLog.info(
                                        feature = "standalone",
                                        message = "link computer opened from home",
                                        fields = mapOf("decision" to "open_pairing"),
                                    )
                                }
                            },
                            onLinkLocalRuntime = {
                                scope.launch {
                                    localAutoLinkAttempted = true
                                    runSilentLocalLink("button")
                                }
                            },
                            onDictate = {
                                if (dictationState.isListening) {
                                    dictation.stop()
                                } else if (draftComposerState.canEdit) {
                                    dictation.start(draftComposerState.text, draftComposerViewModel::update)
                                }
                            },
                            onRetry = {
                                pairedComputer?.let { sessionViewModel.connect(it, force = true) }
                            },
                            onChooseProject = {
                                sessionViewModel.clearAttachments()
                                destination = LauncherDestination.PROJECT
                            },
                            onAllApps = { destination = LauncherDestination.APPS },
                            onAndroidSettings = ::openAndroidSettings,
                            onConnectionHelp = { connectionHelpVisible = true },
                            onManageComputer = { unpairConfirmVisible = true },
                            onOpenTask = { taskId ->
                                if (sessionViewModel.openTask(taskId)) {
                                    sessionViewModel.clearAttachments()
                                    transcriptDetail = null
                                    destination = LauncherDestination.TASK
                                }
                            },
                            connectionHelpVisible = connectionHelpVisible,
                        )
                    LauncherDestination.TASK ->
                        sessionUiState.transcript?.let { transcript ->
                            val taskSummary = sessionUiState.snapshot?.tasks?.singleOrNull { it.id == transcript.taskId }
                            val thread = TaskThreadAssembler.assemble(transcript, decisionState)
                            // Both the tappable "answer this question" flow and typed
                            // text (routed through TypedTextRoute.ANSWER) resolve a
                            // pending question the same way: answer its first
                            // question with the given text. Returns whether an
                            // answer was actually sent, not the protocol outcome.
                            val answerPinnedQuestion: suspend (String) -> Boolean = answer@{ text ->
                                val requestId = thread.pinnedAsk?.requestId ?: return@answer false
                                val request = decisionState.requests.firstOrNull { it.requestId == requestId } ?: return@answer false
                                val question = request.questions.firstOrNull() ?: return@answer false
                                sessionViewModel.answerDecision(requestId, mapOf(question.id to listOf(text)))
                                true
                            }
                            TaskScreen(
                                state = transcript,
                                onBack = {
                                    sessionViewModel.clearAttachments()
                                    sessionViewModel.closeTask()
                                    transcriptDetail = null
                                    destination = LauncherDestination.HOME
                                },
                                onLoadEarlier = { sessionViewModel.loadEarlierTranscript() },
                                onViewCommandOutput = { entry ->
                                    transcriptDetail = TranscriptDetail.Command(entry)
                                    destination = LauncherDestination.TASK_DETAIL
                                },
                                onViewFileChange = { entry, change ->
                                    transcriptDetail = TranscriptDetail.File(entry, change)
                                    destination = LauncherDestination.TASK_DETAIL
                                },
                                taskActionsAvailable = sessionUiState.taskManagementAvailable,
                                unresolvedFork = transcript.taskId in sessionUiState.unconfirmedForkTaskIds,
                                onRenameTask = { title -> sessionViewModel.renameTask(transcript.taskId, title) },
                                onArchiveTask = {
                                    sessionViewModel.clearAttachments()
                                    sessionViewModel.archiveTask(transcript.taskId)
                                },
                                onForkTask = { sessionViewModel.forkTask(transcript.taskId) },
                                onDismissUnresolvedFork = { sessionViewModel.dismissUnconfirmedFork(transcript.taskId) },
                                taskState = taskSummary?.state?.takeIf { sessionUiState.taskControlsAvailable },
                                canRedirect = taskSummary?.canRedirect == true,
                                queueState = taskSummary?.queueState ?: app.codexlauncher.task.summary.TaskQueueState.NONE,
                                onQueueFollowUp = { text -> sessionViewModel.queueTaskFollowUp(transcript.taskId, text) },
                                onRedirect = { text -> sessionViewModel.redirectTask(transcript.taskId, text) },
                                onStop = { sessionViewModel.stopTask(transcript.taskId) },
                                onDismissUnresolvedControl = { sessionViewModel.dismissUnconfirmedTaskControl(transcript.taskId) },
                                dictationState = dictationState,
                                onToggleDictation = {
                                    if (dictationState.isListening) {
                                        dictation.stop()
                                    } else {
                                        dictation.start(sessionUiState.followUpDraft) { text ->
                                            sessionViewModel.updateTaskFollowUpDraft(transcript.taskId, text)
                                        }
                                    }
                                },
                                followUpText = sessionUiState.followUpDraft,
                                onFollowUpTextChange = { text -> sessionViewModel.updateTaskFollowUpDraft(transcript.taskId, text) },
                                attachments = attachmentUploads,
                                attachmentMessage = attachmentMessage,
                                onAttach = { attachmentChoiceVisible = true },
                                onRemoveAttachment = { uploadId ->
                                    sessionViewModel.removeAttachment(uploadId)
                                    attachmentMessage = null
                                },
                                thread = thread,
                                onAskDecision = { decision ->
                                    thread.pinnedAsk?.let { pinned -> scope.launch { sessionViewModel.respondToDecision(pinned.requestId, decision) } }
                                },
                                onAskReply = { text -> scope.launch { answerPinnedQuestion(text) } },
                                onAskNotNow = { thread.pinnedAsk?.let { sessionViewModel.dismissQuestion(it.requestId) } },
                                typedTextAnswers = ThreadAskPolicy.routeTypedText(thread.pinnedAsk, "") == TypedTextRoute.ANSWER,
                                onAnswer = answerPinnedQuestion,
                            )
                        } ?: LauncherLoadingScreen()
                    LauncherDestination.TASK_DETAIL ->
                        transcriptDetail?.let { detail ->
                            TranscriptDetailScreen(
                                detail = detail,
                                onBack = {
                                    transcriptDetail = null
                                    destination = LauncherDestination.TASK
                                },
                            )
                        } ?: LauncherLoadingScreen()
                    LauncherDestination.PROJECT ->
                        ProjectSelector(
                            state = visibleProjectSelection(sessionUiState.connection.phase, projectUiState),
                            onSelect = sessionViewModel.projectSelection::submitSelection,
                            onRetrySave = sessionViewModel.projectSelection::submitSaveRetry,
                            onBack = { destination = LauncherDestination.HOME },
                            onAllApps = { destination = LauncherDestination.APPS },
                            onAndroidSettings = ::openAndroidSettings,
                        )
                    LauncherDestination.APPS ->
                        AppDrawerScreen(
                            apps = installedApps,
                            launchFailureMessage = appLaunchFailureMessage,
                            onBack = { destination = rootDestination },
                            onLaunch = { app ->
                                appLaunchFailureMessage =
                                    if (appsRepository.launch(app)) {
                                        null
                                    } else {
                                        "${app.label} could not be opened. Refresh All apps and try again."
                                    }
                            },
                            onAndroidSettings = ::openAndroidSettings,
                            onLauncherSettings = { destination = LauncherDestination.APPEARANCE },
                        )
                    LauncherDestination.APPEARANCE ->
                        AppearanceScreen(
                            mode = appearanceMode,
                            stoppedConversations = stoppedConversations,
                            appLabel = ::appLabelFor,
                            onResume = { key ->
                                stoppedConversations = stoppedConversations.filterNot { it == key }
                                scope.launch(Dispatchers.IO) { launcherApplication.durableStops.resume(key) }
                            },
                            onModeSelected = { mode -> scope.launch { themePreferences.setMode(mode) } },
                            updateStatusMessage = updateStatusMessage,
                            onCheckForUpdates = { runUpdateCheck(manual = true) },
                            onBack = { destination = LauncherDestination.APPS },
                        )
                }
                if (attachmentChoiceVisible) {
                    AttachmentChoiceDialog(
                        onDismiss = { attachmentChoiceVisible = false },
                        onPhoto = {
                            attachmentChoiceVisible = false
                            photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        },
                        onFile = {
                            attachmentChoiceVisible = false
                            documentPicker.launch(arrayOf("image/*", "text/*", "application/pdf", "application/json", "application/zip"))
                        },
                    )
                }
                availableUpdate?.let { candidate ->
                    UpdateAvailableDialog(
                        candidate = candidate,
                        busy = updateBusy,
                        statusMessage = updateStatusMessage,
                        onInstall = { installAvailableUpdate() },
                        onDismiss = {
                            availableUpdate = null
                            if (updateStatusMessage?.startsWith("Update alpha-") == true) {
                                updateStatusMessage = null
                            }
                        },
                    )
                }
                connectionServiceWarning?.let { warning ->
                    BackgroundConnectionWarningDialog(
                        warning = warning,
                        onDismiss = { connectionServiceWarning = null },
                    )
                }
                if (notificationAccessBlock.worthAsking) {
                    NotificationAccessDialog(
                        onOpenSettings = {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                            launcherApplication.notificationAccessAsk.dismiss()
                        },
                        onDismiss = { launcherApplication.notificationAccessAsk.dismiss() },
                    )
                }
                lastRepliedConversation?.let { key ->
                    ReplyStopOfferRow(
                        key = key,
                        appLabel = remember(key.packageName) { appLabelFor(key.packageName) },
                        onStop = { scope.launch(Dispatchers.IO) { launcherApplication.durableStops.stop(key) } },
                        onDismiss = { launcherApplication.replyGuard.dismissOffer() },
                    )
                }
                if (unpairConfirmVisible) {
                    UnpairConfirmationDialog(
                        onDismiss = { unpairConfirmVisible = false },
                        onConfirm = {
                            unpairConfirmVisible = false
                            removeLocalData()
                        },
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    internal fun handleIncomingIntent(intent: Intent) {
        if (intent.action == Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_HOME)) {
            homeIntentSequence += 1
            AppLog.info(
                feature = "launcher",
                message = "Home intent received",
                fields = mapOf("decision" to "show_home", "input_shape" to "main+home"),
            )
        }
    }

    /**
     * The reply-stop offer only ever has a package name, the same spelling
     * the reply path already keys conversations by. This turns that into
     * the label the person actually recognises on their phone, falling back
     * to the package name itself if Android has nothing installed under it
     * any more.
     */
    private fun appLabelFor(packageName: String): String =
        try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0)).toString()
        } catch (error: PackageManager.NameNotFoundException) {
            packageName
        }

    private fun openAndroidSettings() {
        AppLog.info(
            feature = "launcher",
            message = "opening Android Settings",
            fields = mapOf("output_shape" to "intent_action=${Settings.ACTION_SETTINGS}"),
        )
        startActivity(Intent(Settings.ACTION_SETTINGS))
    }

}

internal enum class LauncherDestination {
    PAIRING,
    HOME,
    PROJECT,
    TASK,
    TASK_DETAIL,
    APPS,
    APPEARANCE,
}

internal sealed interface PairingRecordState {
    data object Loading : PairingRecordState

    data object RecoveryFailed : PairingRecordState

    data class Loaded(val record: PairedComputer?) : PairingRecordState
}

private enum class LocalStorageUiState {
    RECOVERING,
    READY,
    WIPING,
    FAILED,
}

internal fun PairingRecordState.startDestination(): LauncherDestination? =
    when (this) {
        PairingRecordState.Loading -> null
        PairingRecordState.RecoveryFailed -> null
        is PairingRecordState.Loaded -> LauncherDestination.HOME
    }

internal fun visibleDestination(
    root: LauncherDestination,
    requested: LauncherDestination,
    phase: ConnectionPhase = ConnectionPhase.ONLINE,
    hasTranscript: Boolean = true,
    hasDetail: Boolean = true,
): LauncherDestination =
    when (requested) {
        LauncherDestination.HOME -> root
        LauncherDestination.PAIRING -> LauncherDestination.PAIRING
        LauncherDestination.PROJECT -> if (root == LauncherDestination.HOME) requested else root
        LauncherDestination.TASK ->
            if (root == LauncherDestination.HOME && phase == ConnectionPhase.ONLINE && hasTranscript) requested else root
        LauncherDestination.TASK_DETAIL ->
            when {
                root != LauncherDestination.HOME -> root
                phase != ConnectionPhase.ONLINE || !hasTranscript -> LauncherDestination.HOME
                hasDetail -> LauncherDestination.TASK_DETAIL
                else -> LauncherDestination.TASK
            }
        LauncherDestination.APPS, LauncherDestination.APPEARANCE -> requested
    }

internal fun visibleProjectSelection(
    phase: ConnectionPhase,
    state: ProjectSelectionUiState,
): ProjectSelectionUiState = if (phase == ConnectionPhase.ONLINE) state else ProjectSelectionUiState()
