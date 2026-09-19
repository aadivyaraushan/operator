package app.codexlauncher.capability.handoff

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import app.codexlauncher.diagnostics.AppLog

/**
 * Known Android packages for class-H hand-off apps. The capability_result
 * wire only carries handedOffTo by display name, so the phone maps that
 * name to a launch package here instead of extending the protocol.
 */
object HandOffActions {
    fun androidPackage(appName: String): String? =
        when (appName.trim().lowercase()) {
            "instagram" -> "com.instagram.android"
            "venmo" -> "com.venmo"
            "cash app" -> "com.squareup.cash"
            "zelle" -> "com.zellepay.zelle"
            "starbucks" -> "com.starbucks.mobilecard"
            "chipotle" -> "com.chipotle.ordering"
            "spotify" -> "com.spotify.music"
            "audible" -> "com.audible.application"
            "apple music" -> "com.apple.android.music"
            "messages" -> "com.google.android.apps.messaging"
            "discord" -> "com.discord"
            "uber" -> "com.ubercab"
            "uber eats" -> "com.ubercab.eats"
            "resy" -> "com.resy.android.prod"
            "doordash" -> "com.dd.doordash"
            "google photos" -> "com.google.android.apps.photos"
            "teams" -> "com.microsoft.teams"
            "booking.com" -> "com.booking"
            "tripadvisor" -> "com.tripadvisor.tripadvisor"
            "viator" -> "com.viator.mobile.android"
            "stubhub" -> "com.stubhub"
            "alltrails" -> "com.alltrails.alltrails"
            "taskrabbit" -> "com.taskrabbit.droid.consumer"
            "thumbtack" -> "com.thumbtack.consumer"
            "credit karma" -> "com.creditkarma.mobile"
            "turbotax" -> "com.intuit.turbotax.mobile"
            "lyft" -> "me.lyft.android"
            "google keep" -> "com.google.android.keep"
            "whatsapp" -> "com.whatsapp"
            "messenger" -> "com.facebook.orca"
            "signal" -> "org.thoughtcrime.securesms"
            "google maps" -> "com.google.android.apps.maps"
            "netflix" -> "com.netflix.mediaclient"
            "facebook" -> "com.facebook.katana"
            "united" -> "com.united.mobile.android"
            "delta" -> "com.delta.mobile.android"
            "southwest" -> "com.southwestairlines.mobile"
            "american airlines" -> "com.aa.android"
            "citymapper" -> "com.citymapper.app.release"
            "youtube" -> "com.google.android.youtube"
            "airbnb" -> "com.airbnb.android"
            "opentable" -> "com.opentable"
            "grubhub" -> "com.grubhub.android"
            "threads" -> "com.instagram.barcelona"
            "tiktok" -> "com.zhiliaoapp.musically"
            "expedia" -> "com.expedia.bookings"
            "target" -> "com.target.ui"
            "walmart" -> "com.walmart.android"
            "nike" -> "com.nike.omega"
            "sephora" -> "com.sephora"
            "wayfair" -> "com.wayfair.wayfair"
            "kayak" -> "com.kayak.android"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 51→54 HandOffActions for Priceline/LinkedIn/eBay.
            "priceline" -> "com.priceline.android.negotiator"
            "linkedin" -> "com.linkedin.android"
            "ebay" -> "com.ebay.mobile"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 54→55 HandOffActions for Pinterest.
            "pinterest" -> "com.pinterest"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 55→58 HandOffActions for Duolingo/Fitbit/Shazam.
            "duolingo" -> "com.duolingo"
            "fitbit" -> "com.fitbit.FitbitMobile"
            "shazam" -> "com.shazam.android"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 58→61 HandOffActions for Chromecast/YouTube Music/SoundCloud.
            "chromecast" -> "com.google.android.apps.chromecast.app"
            "youtube music" -> "com.google.android.apps.youtube.music"
            "youtubemusic" -> "com.google.android.apps.youtube.music"
            "soundcloud" -> "com.soundcloud.android"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 61→64 HandOffActions for Pandora/Asana/Trello.
            "pandora" -> "com.pandora.android"
            "asana" -> "com.asana.app"
            "trello" -> "com.trello"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 64→67 HandOffActions for mstodo/googledocs/dropbox.
            "microsoft to do" -> "com.microsoft.todos"
            "mstodo" -> "com.microsoft.todos"
            "google docs" -> "com.google.android.apps.docs.editors.docs"
            "googledocs" -> "com.google.android.apps.docs.editors.docs"
            "dropbox" -> "com.dropbox.android"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 67→70 HandOffActions for googlesheets/evernote/googleslides.
            "google sheets" -> "com.google.android.apps.docs.editors.sheets"
            "googlesheets" -> "com.google.android.apps.docs.editors.sheets"
            "evernote" -> "com.evernote"
            "google slides" -> "com.google.android.apps.docs.editors.slides"
            "googleslides" -> "com.google.android.apps.docs.editors.slides"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 70→73 HandOffActions for pocketcasts/goodreads/kindle.
            "pocket casts" -> "au.com.shiftyjelly.pocketcasts"
            "pocketcasts" -> "au.com.shiftyjelly.pocketcasts"
            "goodreads" -> "com.goodreads"
            "kindle" -> "com.amazon.kindle"
            // Callers: HandOffActions.openApp / androidPackage; User ask: Wave1Specs 73→76 HandOffActions for claude/chatgpt/grok.
            "claude" -> "com.anthropic.claude"
            "chatgpt" -> "com.openai.chatgpt"
            "chat gpt" -> "com.openai.chatgpt"
            "grok" -> "ai.x.grok"
            "gmail" -> "com.google.android.gm"
            "google calendar" -> "com.google.android.calendar"
            "slack" -> "com.Slack"
            "notion" -> "notion.id"
            "waze" -> "com.waze"
            "zoom" -> "us.zoom.videomeetings"
            "ticketmaster" -> "com.ticketmaster.mobile.android.na"
            "instacart" -> "com.instacart.client"
            else -> null
        }

    /** Best-effort paste text from a hand-off preview: skip hint/instruction lines. */
    fun draftFromPreviewLines(lines: List<String>): String? =
        lines
            .map { it.trim() }
            .firstOrNull { line ->
                line.isNotEmpty() &&
                    !line.startsWith("For:", ignoreCase = true) &&
                    !line.startsWith("Operator opens", ignoreCase = true)
            }

    fun openApp(context: Context, appName: String): Boolean {
        val packageName = androidPackage(appName) ?: return false
        return try {
            val launch = context.packageManager.getLaunchIntentForPackage(packageName) ?: return false
            context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            AppLog.info(
                feature = "handoff",
                message = "hand-off app opened",
                fields = mapOf("app" to appName, "package" to packageName, "decision" to "launch_main_activity"),
            )
            true
        } catch (error: RuntimeException) {
            if (error !is SecurityException && error !is ActivityNotFoundException) throw error
            AppLog.info(
                feature = "handoff",
                message = "hand-off app open failed",
                fields = mapOf("app" to appName, "package" to packageName, "error_class" to error.javaClass.simpleName, "decision" to "launch_failed"),
            )
            false
        }
    }
}
