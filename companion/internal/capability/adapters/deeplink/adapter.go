// Package deeplink is the shared Wave-1 class-H prepare-and-open adapter.
// One Spec per app (Venmo, Cash App, Zelle, Starbucks, Chipotle, Spotify,
// Audible, Apple Music, Messages, Discord, Uber, Uber Eats, Resy, DoorDash,
// Google Photos, Teams, Booking.com, Tripadvisor, Viator, StubHub, AllTrails,
// Taskrabbit, Thumbtack, Credit Karma, TurboTax, Lyft, Google Keep,
// WhatsApp, Messenger, Signal, Google Maps, Netflix, Facebook,
// United, Delta, Southwest, American Airlines, Citymapper);
// no OAuth, no completion claims — only draft text plus open-package hand-off.
package deeplink

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapter"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/handoff"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/manifest"
)

var ErrEmptyDraft = errors.New("deeplink: draft text must not be empty")

// Spec names one hand-off app. Money apps use compose (pay is not a verb);
// food apps use order or read; media (Spotify/Apple Music/Netflix play|write,
// Audible read|play) is prepare-and-open; Messages, Discord, and Facebook
// personal use compose; Uber/Lyft estimates use rides/read; Uber Eats/Resy
// use food/read; DoorDash uses food read|order; services (Taskrabbit/
// Thumbtack) use compose; finance (Credit Karma/TurboTax) use read; shopping
// (Target/Walmart/Nike/Sephora/Wayfair/eBay) use read browse/open only; Google Keep notes use write;
// WhatsApp/Messenger/Signal/LinkedIn/Pinterest use compose (never send — notification reply is
// separate); Google Maps travel uses read (directions) or write (saved-place
// intent); airlines + Citymapper + Kayak + Priceline use travel/read (flight status /
// manage-booking browse / transit directions / trip search — never book).
// Ceiling is always hands_off. AppClass feeds stage2 ClassMap.
type Spec struct {
	ID             string
	AppName        string
	AndroidPackage string
	Verbs          []manifest.Verb
	AppClass       string
	ProvesCeiling  string
}

// Wave1Specs is the overnight Group A deep-link pack.
func Wave1Specs() []Spec {
	return []Spec{
		{ID: "venmo", AppName: "Venmo", AndroidPackage: "com.venmo", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "money", ProvesCeiling: "venmo_draft_open_smoke"},
		{ID: "cashapp", AppName: "Cash App", AndroidPackage: "com.squareup.cash", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "money", ProvesCeiling: "cashapp_draft_open_smoke"},
		{ID: "zelle", AppName: "Zelle", AndroidPackage: "com.zellepay.zelle", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "money", ProvesCeiling: "zelle_draft_open_smoke"},
		{ID: "starbucks", AppName: "Starbucks", AndroidPackage: "com.starbucks.mobilecard", Verbs: []manifest.Verb{manifest.Order}, AppClass: "food", ProvesCeiling: "starbucks_draft_open_smoke"},
		{ID: "chipotle", AppName: "Chipotle", AndroidPackage: "com.chipotle.ordering", Verbs: []manifest.Verb{manifest.Order}, AppClass: "food", ProvesCeiling: "chipotle_draft_open_smoke"},
		{ID: "spotify", AppName: "Spotify", AndroidPackage: "com.spotify.music", Verbs: []manifest.Verb{manifest.Play, manifest.Write}, AppClass: "media", ProvesCeiling: "spotify_prepare_open_smoke"},
		{ID: "audible", AppName: "Audible", AndroidPackage: "com.audible.application", Verbs: []manifest.Verb{manifest.Read, manifest.Play}, AppClass: "media", ProvesCeiling: "audible_prepare_open_smoke"},
		// Play Store id=com.apple.android.music — prepare-and-open peer of Spotify (no MusicKit/API).
		{ID: "applemusic", AppName: "Apple Music", AndroidPackage: "com.apple.android.music", Verbs: []manifest.Verb{manifest.Play, manifest.Write}, AppClass: "media", ProvesCeiling: "applemusic_prepare_open_smoke"},
		// Plan row "iMessage" on Android-first product = Google Messages compose hand-off.
		{ID: "messages", AppName: "Messages", AndroidPackage: "com.google.android.apps.messaging", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "messages_prepare_open_smoke"},
		// Plan row Discord servers/DMs: prepare-and-open only — no bot, webhook, self-bot, or token.
		{ID: "discord", AppName: "Discord", AndroidPackage: "com.discord", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "discord_prepare_open_smoke"},
		// Play Store id=com.ubercab — estimates only (plan Uber estimates row); never book.
		{ID: "uber", AppName: "Uber", AndroidPackage: "com.ubercab", Verbs: []manifest.Verb{manifest.Read}, AppClass: "rides", ProvesCeiling: "uber_estimates_prepare_open_smoke"},
		// Play Store id=com.ubercab.eats — vendor-confirmed hand-off browse only.
		{ID: "ubereats", AppName: "Uber Eats", AndroidPackage: "com.ubercab.eats", Verbs: []manifest.Verb{manifest.Read}, AppClass: "food", ProvesCeiling: "ubereats_prepare_open_smoke"},
		// Play Store id=com.resy.android.prod — availability read only; booking stays in Resy.
		{ID: "resy", AppName: "Resy", AndroidPackage: "com.resy.android.prod", Verbs: []manifest.Verb{manifest.Read}, AppClass: "food", ProvesCeiling: "resy_prepare_open_smoke"},
		// Play Store id=com.dd.doordash — read/order hand-off; checkout status unconfirmed.
		{ID: "doordash", AppName: "DoorDash", AndroidPackage: "com.dd.doordash", Verbs: []manifest.Verb{manifest.Read, manifest.Order}, AppClass: "food", ProvesCeiling: "doordash_prepare_open_smoke"},
		// Library API full-library scopes removed 2025-03-31; Wave 1 is prepare-and-open only.
		{ID: "googlephotos", AppName: "Google Photos", AndroidPackage: "com.google.android.apps.photos", Verbs: []manifest.Verb{manifest.Read, manifest.Write}, AppClass: "media", ProvesCeiling: "googlephotos_prepare_open_smoke"},
		// Personal Teams: Graph chat send does not support personal accounts — compose hand-off only.
		{ID: "teams", AppName: "Teams", AndroidPackage: "com.microsoft.teams", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "teams_personal_prepare_open_smoke"},
		// Play Store id=com.booking — vendor-confirmed search-only; never claim a reservation.
		{ID: "booking", AppName: "Booking.com", AndroidPackage: "com.booking", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "booking_search_prepare_open_smoke"},
		// Play Store id=com.tripadvisor.tripadvisor — Wave 1 connector hands_off until smoke proves otherwise.
		{ID: "tripadvisor", AppName: "Tripadvisor", AndroidPackage: "com.tripadvisor.tripadvisor", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "tripadvisor_search_prepare_open_smoke"},
		// Play Store id=com.viator.mobile.android (com.viator.mobile.consumer 404); Partner API is partner-gated.
		{ID: "viator", AppName: "Viator", AndroidPackage: "com.viator.mobile.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "viator_search_prepare_open_smoke"},
		// Play Store id=com.stubhub — Wave 1 connector hands_off until smoke proves otherwise.
		{ID: "stubhub", AppName: "StubHub", AndroidPackage: "com.stubhub", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "stubhub_search_prepare_open_smoke"},
		// Play Store id=com.alltrails.alltrails — no public consumer API; hands_off until user-delegated route exists.
		{ID: "alltrails", AppName: "AllTrails", AndroidPackage: "com.alltrails.alltrails", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "alltrails_search_prepare_open_smoke"},
		// Play Store id=com.taskrabbit.droid.consumer — NO-BD partner-gated API; Wave 1 compose hand-off only.
		{ID: "taskrabbit", AppName: "Taskrabbit", AndroidPackage: "com.taskrabbit.droid.consumer", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "services", ProvesCeiling: "taskrabbit_prepare_open_smoke"},
		// Play Store id=com.thumbtack.consumer — NO-BD partner approval; Wave 1 compose hand-off only.
		{ID: "thumbtack", AppName: "Thumbtack", AndroidPackage: "com.thumbtack.consumer", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "services", ProvesCeiling: "thumbtack_prepare_open_smoke"},
		// Play Store id=com.creditkarma.mobile — NO-DOOR (no public API); demote plan completes → hands_off read.
		{ID: "creditkarma", AppName: "Credit Karma", AndroidPackage: "com.creditkarma.mobile", Verbs: []manifest.Verb{manifest.Read}, AppClass: "finance", ProvesCeiling: "creditkarma_prepare_open_smoke"},
		// Play Store id=com.intuit.turbotax.mobile — NO-DOOR (no public API); demote plan completes → hands_off read.
		{ID: "turbotax", AppName: "TurboTax", AndroidPackage: "com.intuit.turbotax.mobile", Verbs: []manifest.Verb{manifest.Read}, AppClass: "finance", ProvesCeiling: "turbotax_prepare_open_smoke"},
		// Play Store id=me.lyft.android (com.lyft.android 404) — peer of Uber estimates; hands_off until BD/API.
		{ID: "lyft", AppName: "Lyft", AndroidPackage: "me.lyft.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "rides", ProvesCeiling: "lyft_estimates_prepare_open_smoke"},
		// Play Store id=com.google.android.keep — Android Notes stand-in (Apple Notes is Mac RT-6); draft write only.
		{ID: "googlekeep", AppName: "Google Keep", AndroidPackage: "com.google.android.keep", Verbs: []manifest.Verb{manifest.Write}, AppClass: "notes", ProvesCeiling: "googlekeep_prepare_open_smoke"},
		// Wave 3 / class H: prepare-and-open compose only. Notification reply is ReplyCapability (separate).
		// Play Store id=com.whatsapp — HTTP 200.
		{ID: "whatsapp", AppName: "WhatsApp", AndroidPackage: "com.whatsapp", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "whatsapp_prepare_open_smoke"},
		// Play Store id=com.facebook.orca — HTTP 200.
		{ID: "messenger", AppName: "Messenger", AndroidPackage: "com.facebook.orca", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "messenger_prepare_open_smoke"},
		// Play Store id=org.thoughtcrime.securesms — HTTP 200.
		{ID: "signal", AppName: "Signal", AndroidPackage: "org.thoughtcrime.securesms", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "signal_prepare_open_smoke"},
		// Play Store id=com.google.android.apps.maps — HTTP 200. One Spec: directions (read) + saved-place intent (write).
		{ID: "googlemaps", AppName: "Google Maps", AndroidPackage: "com.google.android.apps.maps", Verbs: []manifest.Verb{manifest.Read, manifest.Write}, AppClass: "travel", ProvesCeiling: "googlemaps_prepare_open_smoke"},
		// Play Store id=com.netflix.mediaclient — HTTP 200. play (search/open title) + write (My List intent); never claim played/added.
		{ID: "netflix", AppName: "Netflix", AndroidPackage: "com.netflix.mediaclient", Verbs: []manifest.Verb{manifest.Play, manifest.Write}, AppClass: "media", ProvesCeiling: "netflix_prepare_open_smoke"},
		// Play Store id=com.facebook.katana — HTTP 200. Personal posts: compose hands_off; never claim posted.
		// AppClass messaging (stage1 has no social class; matches Discord/WhatsApp compose peers).
		{ID: "facebook", AppName: "Facebook", AndroidPackage: "com.facebook.katana", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "facebook_prepare_open_smoke"},
		// Play Store id=com.united.mobile.android — HTTP 200. Flight status / manage-booking browse; never book.
		{ID: "united", AppName: "United", AndroidPackage: "com.united.mobile.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "united_prepare_open_smoke"},
		// Play Store id=com.delta.mobile.android — HTTP 200. Flight status / manage-booking browse; never book.
		{ID: "delta", AppName: "Delta", AndroidPackage: "com.delta.mobile.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "delta_prepare_open_smoke"},
		// Play Store id=com.southwestairlines.mobile — HTTP 200 (com.southwestair.mobile 404). Never book.
		{ID: "southwest", AppName: "Southwest", AndroidPackage: "com.southwestairlines.mobile", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "southwest_prepare_open_smoke"},
		// Play Store id=com.aa.android — HTTP 200. Flight status / manage-booking browse; never book.
		{ID: "american", AppName: "American Airlines", AndroidPackage: "com.aa.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "american_prepare_open_smoke"},
		// Play Store id=com.citymapper.app.release — HTTP 200. Transit directions read; never book.
		{ID: "citymapper", AppName: "Citymapper", AndroidPackage: "com.citymapper.app.release", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "citymapper_prepare_open_smoke"},
		// Play Store id=com.google.android.youtube — HTTP 200. play (open/search title) + read (browse/search); never claim played.
		{ID: "youtube", AppName: "YouTube", AndroidPackage: "com.google.android.youtube", Verbs: []manifest.Verb{manifest.Play, manifest.Read}, AppClass: "media", ProvesCeiling: "youtube_prepare_open_smoke"},
		// Play Store id=com.airbnb.android — HTTP 200. Search/prepare-and-open; Wave 3 book demoted → read; never claim booked.
		{ID: "airbnb", AppName: "Airbnb", AndroidPackage: "com.airbnb.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "airbnb_search_prepare_open_smoke"},
		// Play Store id=com.opentable — HTTP 200. Availability read; Wave 3 book demoted → read; never claim reservation booked.
		{ID: "opentable", AppName: "OpenTable", AndroidPackage: "com.opentable", Verbs: []manifest.Verb{manifest.Read}, AppClass: "food", ProvesCeiling: "opentable_prepare_open_smoke"},
		// Play Store id=com.grubhub.android — HTTP 200. read/order hand-off; never claim checkout completed.
		{ID: "grubhub", AppName: "Grubhub", AndroidPackage: "com.grubhub.android", Verbs: []manifest.Verb{manifest.Read, manifest.Order}, AppClass: "food", ProvesCeiling: "grubhub_prepare_open_smoke"},
		// Play Store id=com.instagram.barcelona — HTTP 200. Compose hands_off; Wave 2 post/reply → overnight compose only; never claim posted/replied.
		// AppClass messaging (stage1 has no social class; matches Facebook compose peer).
		{ID: "threads", AppName: "Threads", AndroidPackage: "com.instagram.barcelona", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "threads_prepare_open_smoke"},
		// Play Store id=com.zhiliaoapp.musically — HTTP 200 (com.ss.android.ugc.trill 404). Compose hands_off; never claim posted.
		// AppClass messaging (match Facebook; media ClassMap verbs are play/read/write).
		{ID: "tiktok", AppName: "TikTok", AndroidPackage: "com.zhiliaoapp.musically", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "tiktok_prepare_open_smoke"},
		// Play Store id=com.expedia.bookings — HTTP 200. Search/prepare-and-open; Wave 3 book demoted → read; never claim booked.
		{ID: "expedia", AppName: "Expedia", AndroidPackage: "com.expedia.bookings", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "expedia_search_prepare_open_smoke"},
		// Shopping browse/open only (Wave 3; no UCP cart API). Play packages HTTP 200 (2026-08-02).
		// Verb read — never claim cart built, ordered, or checkout completed.
		{ID: "target", AppName: "Target", AndroidPackage: "com.target.ui", Verbs: []manifest.Verb{manifest.Read}, AppClass: "shopping", ProvesCeiling: "target_prepare_open_smoke"},
		{ID: "walmart", AppName: "Walmart", AndroidPackage: "com.walmart.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "shopping", ProvesCeiling: "walmart_prepare_open_smoke"},
		{ID: "nike", AppName: "Nike", AndroidPackage: "com.nike.omega", Verbs: []manifest.Verb{manifest.Read}, AppClass: "shopping", ProvesCeiling: "nike_prepare_open_smoke"},
		// Play Store id=com.sephora — HTTP 200 (2026-08-02). Browse/open read only.
		{ID: "sephora", AppName: "Sephora", AndroidPackage: "com.sephora", Verbs: []manifest.Verb{manifest.Read}, AppClass: "shopping", ProvesCeiling: "sephora_prepare_open_smoke"},
		// Play Store id=com.wayfair.wayfair — HTTP 200 (2026-08-02). Browse/open read only.
		{ID: "wayfair", AppName: "Wayfair", AndroidPackage: "com.wayfair.wayfair", Verbs: []manifest.Verb{manifest.Read}, AppClass: "shopping", ProvesCeiling: "wayfair_prepare_open_smoke"},
		// Play Store id=com.kayak.android — HTTP 200 (2026-08-02). Search/prepare-and-open; Wave 3 book demoted → read; never claim booked.
		{ID: "kayak", AppName: "Kayak", AndroidPackage: "com.kayak.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "kayak_search_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 51 → 54 — priceline/linkedin/ebay prepare-and-open.
		// Play Store id=com.priceline.android.negotiator — HTTP 200 (2026-08-02). Travel search; book demoted → read; never claim booked.
		{ID: "priceline", AppName: "Priceline", AndroidPackage: "com.priceline.android.negotiator", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "priceline_search_prepare_open_smoke"},
		// Play Store id=com.linkedin.android — HTTP 200 (2026-08-02). Compose hand-off only (Facebook/Threads peer); never claim posted/commented. No OAuth.
		{ID: "linkedin", AppName: "LinkedIn", AndroidPackage: "com.linkedin.android", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "linkedin_prepare_open_smoke"},
		// Play Store id=com.ebay.mobile — HTTP 200 (2026-08-02). Shopping browse/open read only; never claim cart/bid/checkout.
		{ID: "ebay", AppName: "eBay", AndroidPackage: "com.ebay.mobile", Verbs: []manifest.Verb{manifest.Read}, AppClass: "shopping", ProvesCeiling: "ebay_browse_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 54 → 55 — Pinterest prepare-and-open.
		// Play Store id=com.pinterest — HTTP 200 (2026-08-02). Compose hands_off (Facebook/Threads peer); never claim pinned/posted/saved.
		{ID: "pinterest", AppName: "Pinterest", AndroidPackage: "com.pinterest", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "pinterest_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 55 → 58 — Duolingo/Fitbit/Shazam prepare-and-open.
		// Play Store id=com.duolingo — HTTP 200 (2026-08-02). Services read browse/open; never claim lesson completed.
		{ID: "duolingo", AppName: "Duolingo", AndroidPackage: "com.duolingo", Verbs: []manifest.Verb{manifest.Read}, AppClass: "services", ProvesCeiling: "duolingo_prepare_open_smoke"},
		// Play Store id=com.fitbit.FitbitMobile — HTTP 200 (2026-08-02). Services read browse/open; never claim workout logged/synced/saved.
		{ID: "fitbit", AppName: "Fitbit", AndroidPackage: "com.fitbit.FitbitMobile", Verbs: []manifest.Verb{manifest.Read}, AppClass: "services", ProvesCeiling: "fitbit_prepare_open_smoke"},
		// Play Store id=com.shazam.android — HTTP 200 (2026-08-02). Media read identify/search intent; never claim identified/played/saved.
		{ID: "shazam", AppName: "Shazam", AndroidPackage: "com.shazam.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "media", ProvesCeiling: "shazam_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 58 → 61 — Chromecast/YouTube Music/SoundCloud prepare-and-open.
		// Play Store id=com.google.android.apps.chromecast.app — HTTP 200 (2026-08-02). Media play cast/open intent; never claim cast started/playing/connected.
		{ID: "chromecast", AppName: "Chromecast", AndroidPackage: "com.google.android.apps.chromecast.app", Verbs: []manifest.Verb{manifest.Play}, AppClass: "media", ProvesCeiling: "chromecast_prepare_open_smoke"},
		// Play Store id=com.google.android.apps.youtube.music — HTTP 200 (2026-08-02). Media play|read like YouTube; never claim played/playlist/library.
		{ID: "youtubemusic", AppName: "YouTube Music", AndroidPackage: "com.google.android.apps.youtube.music", Verbs: []manifest.Verb{manifest.Play, manifest.Read}, AppClass: "media", ProvesCeiling: "youtubemusic_prepare_open_smoke"},
		// Play Store id=com.soundcloud.android — HTTP 200 (2026-08-02). Media play|read like YouTube; never claim played/playlist/library.
		{ID: "soundcloud", AppName: "SoundCloud", AndroidPackage: "com.soundcloud.android", Verbs: []manifest.Verb{manifest.Play, manifest.Read}, AppClass: "media", ProvesCeiling: "soundcloud_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 61 → 64 — Pandora/Asana/Trello prepare-and-open.
		// Play Store id=com.pandora.android — HTTP 200 (2026-08-02). Media play|read like SoundCloud; never claim played/playlist/station changed.
		{ID: "pandora", AppName: "Pandora", AndroidPackage: "com.pandora.android", Verbs: []manifest.Verb{manifest.Play, manifest.Read}, AppClass: "media", ProvesCeiling: "pandora_prepare_open_smoke"},
		// Play Store id=com.asana.app — HTTP 200 (2026-08-02). Tasks write create/open intent; never claim task created/assigned/completed. Not Todoist RT-2.
		{ID: "asana", AppName: "Asana", AndroidPackage: "com.asana.app", Verbs: []manifest.Verb{manifest.Write}, AppClass: "tasks", ProvesCeiling: "asana_prepare_open_smoke"},
		// Play Store id=com.trello — HTTP 200 (2026-08-02). Tasks write create/open card intent; never claim card moved/assigned/completed. Not Todoist RT-2.
		{ID: "trello", AppName: "Trello", AndroidPackage: "com.trello", Verbs: []manifest.Verb{manifest.Write}, AppClass: "tasks", ProvesCeiling: "trello_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 64 → 67 — Microsoft To Do / Google Docs / Dropbox prepare-and-open.
		// Play Store id=com.microsoft.todos — HTTP 200 (2026-08-02). Tasks write create/open intent; never claim task created/assigned/completed. Not Todoist RT-2.
		{ID: "mstodo", AppName: "Microsoft To Do", AndroidPackage: "com.microsoft.todos", Verbs: []manifest.Verb{manifest.Write}, AppClass: "tasks", ProvesCeiling: "mstodo_prepare_open_smoke"},
		// Play Store id=com.google.android.apps.docs.editors.docs — HTTP 200 (2026-08-02). Notes write draft/open doc intent; never claim doc created/saved/shared. Separate from Google Drive OAuth.
		{ID: "googledocs", AppName: "Google Docs", AndroidPackage: "com.google.android.apps.docs.editors.docs", Verbs: []manifest.Verb{manifest.Write}, AppClass: "notes", ProvesCeiling: "googledocs_prepare_open_smoke"},
		// Play Store id=com.dropbox.android — HTTP 200 (2026-08-02). Notes read browse/open file intent; never claim uploaded/downloaded/shared/synced.
		{ID: "dropbox", AppName: "Dropbox", AndroidPackage: "com.dropbox.android", Verbs: []manifest.Verb{manifest.Read}, AppClass: "notes", ProvesCeiling: "dropbox_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 67 → 70 — Google Sheets / Evernote / Google Slides prepare-and-open.
		// Play Store id=com.google.android.apps.docs.editors.sheets — HTTP 200 (2026-08-02). Notes write draft/open sheet intent; never claim sheet created/saved/shared. Separate from Drive OAuth and googledocs Spec.
		{ID: "googlesheets", AppName: "Google Sheets", AndroidPackage: "com.google.android.apps.docs.editors.sheets", Verbs: []manifest.Verb{manifest.Write}, AppClass: "notes", ProvesCeiling: "googlesheets_prepare_open_smoke"},
		// Play Store id=com.evernote — HTTP 200 (2026-08-02). Notes write draft/open note intent; never claim notebook created/saved/shared/synced.
		{ID: "evernote", AppName: "Evernote", AndroidPackage: "com.evernote", Verbs: []manifest.Verb{manifest.Write}, AppClass: "notes", ProvesCeiling: "evernote_prepare_open_smoke"},
		// Play Store id=com.google.android.apps.docs.editors.slides — HTTP 200 (2026-08-02). Notes write draft/open slides intent; never claim slide created/saved/shared. Separate from Drive OAuth and googledocs Spec.
		{ID: "googleslides", AppName: "Google Slides", AndroidPackage: "com.google.android.apps.docs.editors.slides", Verbs: []manifest.Verb{manifest.Write}, AppClass: "notes", ProvesCeiling: "googleslides_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 70 → 73 — Pocket Casts / Goodreads / Kindle prepare-and-open.
		// Pack goal: prepare-and-open only; never claim played/downloaded/subscribed, review posted/shelved/rated, purchased/downloaded/read completed.
		// Play Store id=au.com.shiftyjelly.pocketcasts — HTTP 200 (2026-08-02). Media play|read open/search podcast app; never claim played/downloaded/subscribed. Separate from Podcasts RT-2 RSS adapter (podcasts id).
		{ID: "pocketcasts", AppName: "Pocket Casts", AndroidPackage: "au.com.shiftyjelly.pocketcasts", Verbs: []manifest.Verb{manifest.Play, manifest.Read}, AppClass: "media", ProvesCeiling: "pocketcasts_prepare_open_smoke"},
		// Play Store id=com.goodreads — HTTP 200 (2026-08-02). Notes read browse/open book intent; never claim review posted/shelved/rated.
		{ID: "goodreads", AppName: "Goodreads", AndroidPackage: "com.goodreads", Verbs: []manifest.Verb{manifest.Read}, AppClass: "notes", ProvesCeiling: "goodreads_prepare_open_smoke"},
		// Play Store id=com.amazon.kindle — HTTP 200 (2026-08-02). Media read open library/book intent (Kindle reader app); never claim purchased/downloaded/read completed. Not Amazon shopping (C2).
		{ID: "kindle", AppName: "Kindle", AndroidPackage: "com.amazon.kindle", Verbs: []manifest.Verb{manifest.Read}, AppClass: "media", ProvesCeiling: "kindle_prepare_open_smoke"},
		// Callers: Wave1Specs → runtime/deeplink ClassMap, stage1 coaching, HandOffActions, serve-deeplink-proof.
		// User ask: Wave1Specs 73 → 76 — Claude/ChatGPT/Grok prepare-and-open.
		// Pack goal: prepare-and-open draft prompt / open official apps only; never claim replied/sent/answered/completed chat. Operator does not call their APIs.
		// Play Store id=com.anthropic.claude — HTTP 200 (2026-08-02). Messaging compose hand-off.
		{ID: "claude", AppName: "Claude", AndroidPackage: "com.anthropic.claude", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "claude_prepare_open_smoke"},
		// Play Store id=com.openai.chatgpt — HTTP 200 (2026-08-02). Messaging compose hand-off.
		{ID: "chatgpt", AppName: "ChatGPT", AndroidPackage: "com.openai.chatgpt", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "chatgpt_prepare_open_smoke"},
		// Play Store id=ai.x.grok — HTTP 200 (2026-08-02). Messaging compose hand-off.
		{ID: "grok", AppName: "Grok", AndroidPackage: "ai.x.grok", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "grok_prepare_open_smoke"},
		// Wave1Specs 76 → 84. Play package ids and destinations verified 2026-09-10
		// by the same method the earlier rows record: a Play Store id that does not
		// exist answers 404, which this run reproduced for com.lyft.android and
		// com.viator.mobile.consumer, the two already noted above.
		//
		// slack, notion and gcalendar deliberately reuse the ids of the credentialed
		// adapters. production.go skips a deep-link spec whose id a credentialed
		// adapter has taken, so these are the floor a signed-out install gets and
		// the credentialed adapter replaces them rather than sitting beside them.
		// Their AppClass matches what production.go files the credentialed version
		// under, so an adapter's class does not change with its credential state.
		//
		// Yelp was prepared and left out: www.yelp.com answers 403 to any
		// non-browser request, so its destination could not be verified the way
		// every other row here was, and adding it would mean either recording an
		// unfinished check or weakening the officialDomainUnchecked === 0 rule.
		{ID: "gmail", AppName: "Gmail", AndroidPackage: "com.google.android.gm", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "messaging", ProvesCeiling: "gmail_prepare_open_smoke"},
		{ID: "gcalendar", AppName: "Google Calendar", AndroidPackage: "com.google.android.calendar", Verbs: []manifest.Verb{manifest.Write}, AppClass: "calendar", ProvesCeiling: "gcalendar_prepare_open_smoke"},
		{ID: "slack", AppName: "Slack", AndroidPackage: "com.Slack", Verbs: []manifest.Verb{manifest.Compose}, AppClass: "slack", ProvesCeiling: "slack_prepare_open_smoke"},
		{ID: "notion", AppName: "Notion", AndroidPackage: "notion.id", Verbs: []manifest.Verb{manifest.Write}, AppClass: "notes", ProvesCeiling: "notion_prepare_open_smoke"},
		{ID: "waze", AppName: "Waze", AndroidPackage: "com.waze", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "waze_prepare_open_smoke"},
		{ID: "zoom", AppName: "Zoom", AndroidPackage: "us.zoom.videomeetings", Verbs: []manifest.Verb{manifest.Read}, AppClass: "services", ProvesCeiling: "zoom_prepare_open_smoke"},
		{ID: "ticketmaster", AppName: "Ticketmaster", AndroidPackage: "com.ticketmaster.mobile.android.na", Verbs: []manifest.Verb{manifest.Read}, AppClass: "travel", ProvesCeiling: "ticketmaster_prepare_open_smoke"},
		{ID: "instacart", AppName: "Instacart", AndroidPackage: "com.instacart.client", Verbs: []manifest.Verb{manifest.Read}, AppClass: "food", ProvesCeiling: "instacart_prepare_open_smoke"},
	}
}

type Adapter struct {
	spec   Spec
	logger *slog.Logger
}

var _ adapter.Adapter = (*Adapter)(nil)

func New(spec Spec, logger *slog.Logger) *Adapter {
	if logger == nil {
		logger = slog.Default()
	}
	return &Adapter{spec: spec, logger: logger}
}

func (a *Adapter) AppName() string        { return a.spec.AppName }
func (a *Adapter) AndroidPackage() string { return a.spec.AndroidPackage }

func (a *Adapter) Describe() manifest.Manifest {
	return manifest.Manifest{
		ID: a.spec.ID, Runtime: manifest.RT4,
		Verbs:   append([]manifest.Verb(nil), a.spec.Verbs...),
		Ceiling: manifest.HandsOff, Consent: manifest.ConsentA,
		Auth: manifest.AuthNone, Cost: manifest.CostFree,
		Gates:    []manifest.Gate{manifest.GateNone},
		Capacity: manifest.Capacity{Kind: manifest.CapacityNone},
		Region:   []string{"global"}, Platform: manifest.PlatformAndroid,
		ProvesCeiling: a.spec.ProvesCeiling,
	}
}

func (a *Adapter) allows(verb manifest.Verb) bool {
	for _, allowed := range a.spec.Verbs {
		if allowed == verb {
			return true
		}
	}
	return false
}

func (a *Adapter) Resolve(_ context.Context, in adapter.Intent) (adapter.Plan, error) {
	a.logger.Info("[deeplink] resolve", "adapter_id", a.spec.ID, "app_class", a.spec.AppClass, "verb", in.Verb, "subject_length", len(in.Subject), "body_length", len(in.Body))
	if !a.allows(in.Verb) {
		return adapter.Plan{}, fmt.Errorf("deeplink %s: verb %q is not supported; use one of %v", a.spec.ID, in.Verb, a.spec.Verbs)
	}
	draft := strings.TrimSpace(in.Body)
	if draft == "" {
		return adapter.Plan{}, ErrEmptyDraft
	}
	details := map[string]string{
		"draft":           draft,
		"android_package": a.spec.AndroidPackage,
		"app_class":       a.spec.AppClass,
	}
	if subject := strings.TrimSpace(in.Subject); subject != "" {
		details["subject_hint"] = subject
	}
	a.logger.Info("[deeplink] resolve ready", "adapter_id", a.spec.ID, "draft_length", len(draft), "has_subject_hint", details["subject_hint"] != "")
	return adapter.Plan{
		AdapterID: a.spec.ID, Verb: in.Verb,
		Summary: fmt.Sprintf("Prepare a %s draft", a.spec.AppName),
		Details: details,
	}, nil
}

func (a *Adapter) Preview(_ context.Context, plan adapter.Plan) (adapter.Preview, error) {
	draft := plan.Details["draft"]
	a.logger.Info("[deeplink] preview", "adapter_id", a.spec.ID, "draft_length", len(draft))
	lines := make([]string, 0, 3)
	if hint := plan.Details["subject_hint"]; hint != "" {
		lines = append(lines, "For: "+hint+" (you finish in "+a.spec.AppName+")")
	}
	lines = append(lines, draft)
	lines = append(lines, fmt.Sprintf("Operator opens %s only. You finish there.", a.spec.AppName))
	return adapter.Preview{
		Plan:     plan,
		Headline: plan.Summary,
		Lines:    lines,
		Confirm:  "Open " + a.spec.AppName,
	}, nil
}

func (a *Adapter) Execute(_ context.Context, plan adapter.Plan) (adapter.Outcome, error) {
	draft := plan.Details["draft"]
	a.logger.Info("[deeplink] execute", "adapter_id", a.spec.ID, "draft_length", len(draft), "handed_off_to", a.spec.AppName)
	out := handoff.DraftOutcome(a.spec.AppName, draft)
	a.logger.Info("[deeplink] execute complete", "adapter_id", a.spec.ID, "reached", out.Reached, "done", out.Done, "handed_off_to", out.HandedOffTo)
	return out, nil
}

func (a *Adapter) Revoke(context.Context) error {
	a.logger.Info("[deeplink] revoke", "adapter_id", a.spec.ID, "decision", "noop_no_credentials")
	return nil
}
