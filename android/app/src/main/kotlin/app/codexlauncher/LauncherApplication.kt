package app.codexlauncher

import android.app.Application
import androidx.core.app.NotificationManagerCompat
import app.codexlauncher.capability.handoff.youtube.YouTubePlaybackAction
import app.codexlauncher.capability.location.DeviceLocationAction
import app.codexlauncher.capability.reply.access.DeviceNotificationAccess
import app.codexlauncher.capability.reply.access.NotificationAccessAsk
import app.codexlauncher.capability.reply.guard.DurableStops
import app.codexlauncher.capability.reply.guard.ReplyCap
import app.codexlauncher.capability.reply.guard.ReplyGuard
import app.codexlauncher.capability.reply.request.DeviceReplyEntry
import app.codexlauncher.connection.pairing.network.AndroidDevicePairingSigner
import app.codexlauncher.connection.recovery.ConnectionBootstrapper
import app.codexlauncher.connection.runtime.LauncherSessionViewModel
import app.codexlauncher.connection.session.CompanionSessionClient
import app.codexlauncher.connection.stream.LauncherStreamClient
import app.codexlauncher.connection.stream.StreamClient
import app.codexlauncher.diagnostics.AppLog
// Fact-force: importers=AndroidManifest Application; callers=onCreate;
// API=BrokerLoopback.start; user: Maps + OpenAI Go→Android broker RPC, always
// on so a key imported after launch works with no restart
import app.codexlauncher.runtime.broker.rpc.BrokerLoopback
import app.codexlauncher.storage.ownership.LocalStateOwner
import app.codexlauncher.storage.reply.stops.ReplyStopStore
import app.codexlauncher.storage.reply.stops.replyStopDataStore
import app.codexlauncher.task.composer.DraftComposerViewModel
import app.codexlauncher.storage.pairing.PairingRecordReadState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class LauncherApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // ReplyStopStore.read() blocks on disk I/O, so this runs on a
        // background dispatcher rather than in this method directly -- the
        // same reason every other on-demand storage read in this app is a
        // suspend call dispatched off Main, not a synchronous one made here.
        CoroutineScope(Dispatchers.IO).launch {
            val outcome = durableStops.restore()
            AppLog.info(
                feature = "reply-stops",
                message = "startup stop list restore finished",
                fields = mapOf("output_shape" to outcome.name.lowercase()),
            )
            BrokerLoopback.start(this@LauncherApplication)
        }
    }

    val notificationAccessAsk: NotificationAccessAsk by lazy { NotificationAccessAsk() }

    // One instance for the app's whole lifetime, the same reasoning as
    // notificationAccessAsk above: a guard rebuilt on every reply remembers
    // no stop and no send history, so it would enforce neither rule it
    // exists for. Exposed as a val, not private, so a future screen can list
    // and undo stopped conversations.
    val replyGuard: ReplyGuard by lazy { ReplyGuard(now = System::currentTimeMillis, cap = ReplyCap.shipped) }

    // Holds the guard above alongside the durable copy of its stop list, so a
    // stop made from any screen is written down and a restart does not
    // silently forget it. Exposed as a val for the same reason as replyGuard:
    // a screen listing or undoing stops needs the one instance the app is
    // actually enforcing.
    val durableStops: DurableStops by lazy { DurableStops(guard = replyGuard, store = ReplyStopStore(replyStopDataStore)) }
    private val deviceReplyEntry: DeviceReplyEntry by lazy {
        DeviceReplyEntry(
            grantedAtOsLevel = {
                NotificationManagerCompat.getEnabledListenerPackages(this).contains(packageName)
            },
            replyBoxes = DeviceNotificationAccess::currentReplyBoxes,
            dispatch = DeviceNotificationAccess::current,
            ask = notificationAccessAsk,
            guard = replyGuard,
        )
    }
    val localState: LocalStateOwner by lazy { LocalStateOwner(this) }
    val draftComposer: DraftComposerViewModel by lazy {
        DraftComposerViewModel(
            loadDraft = localState.drafts::load,
            saveDraft = localState.drafts::save,
        )
    }
    val session: LauncherSessionViewModel by lazy {
        val client =
            CompanionSessionClient(
                signer = AndroidDevicePairingSigner(localState.pairingKeys),
                loadResumeCursor = localState.resumeCursors::load,
            )
        LauncherSessionViewModel(
            connect = client::connect,
            loadProject = { localState.projectSelections.selected.first() },
            saveProject = localState.projectSelections::save,
            clearProject = localState.projectSelections::clear,
            actionJournal = localState.actionJournal,
            carryOutDeviceReply = deviceReplyEntry::carryOut,
            carryOutYouTubePlayback = { watchUrl -> YouTubePlaybackAction.carryOut(this, watchUrl) },
            fetchLocation = { DeviceLocationAction.fetchLocationJson(this) },
            clearConfirmedDraft = draftComposer::clearAfterConfirmedSend,
            onSuccessfulConnection = { pairingGeneration, epochMillis ->
                localState.lastConnections.record(pairingGeneration, epochMillis)
            },
            recordResumeCursor = localState.resumeCursors::record,
        )
    }
    val streamClient: StreamClient by lazy { LauncherStreamClient(session) }
    val connectionBootstrapper: ConnectionBootstrapper by lazy {
        ConnectionBootstrapper(
            recover = {
                localState.wiper.recover {
                    when (localState.pairingRecords.readForStartup()) {
                        is PairingRecordReadState.Paired -> true
                        PairingRecordReadState.Unpaired -> false
                        PairingRecordReadState.Unavailable -> throw IllegalStateException("Pairing storage is unavailable")
                    }
                }
            },
            readPairing = localState.pairingRecords::readForStartup,
            loadDraft = draftComposer::load,
            connect = session::connect,
        )
    }
}
