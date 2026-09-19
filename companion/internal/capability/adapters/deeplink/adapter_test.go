package deeplink

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapter"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/execution"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/manifest"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/registry"
)

func TestWave1DeepLinkSpecsAreHandsOffPrepareAndOpen(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	want := []struct {
		id, app, pkg, appClass, proves string
		verbs                          []manifest.Verb
	}{
		{"venmo", "Venmo", "com.venmo", "money", "venmo_draft_open_smoke", []manifest.Verb{manifest.Compose}},
		{"cashapp", "Cash App", "com.squareup.cash", "money", "cashapp_draft_open_smoke", []manifest.Verb{manifest.Compose}},
		{"zelle", "Zelle", "com.zellepay.zelle", "money", "zelle_draft_open_smoke", []manifest.Verb{manifest.Compose}},
		{"starbucks", "Starbucks", "com.starbucks.mobilecard", "food", "starbucks_draft_open_smoke", []manifest.Verb{manifest.Order}},
		{"chipotle", "Chipotle", "com.chipotle.ordering", "food", "chipotle_draft_open_smoke", []manifest.Verb{manifest.Order}},
		{"spotify", "Spotify", "com.spotify.music", "media", "spotify_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Write}},
		{"audible", "Audible", "com.audible.application", "media", "audible_prepare_open_smoke", []manifest.Verb{manifest.Read, manifest.Play}},
		{"applemusic", "Apple Music", "com.apple.android.music", "media", "applemusic_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Write}},
		{"messages", "Messages", "com.google.android.apps.messaging", "messaging", "messages_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"discord", "Discord", "com.discord", "messaging", "discord_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"uber", "Uber", "com.ubercab", "rides", "uber_estimates_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"ubereats", "Uber Eats", "com.ubercab.eats", "food", "ubereats_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"resy", "Resy", "com.resy.android.prod", "food", "resy_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"doordash", "DoorDash", "com.dd.doordash", "food", "doordash_prepare_open_smoke", []manifest.Verb{manifest.Read, manifest.Order}},
		{"googlephotos", "Google Photos", "com.google.android.apps.photos", "media", "googlephotos_prepare_open_smoke", []manifest.Verb{manifest.Read, manifest.Write}},
		{"teams", "Teams", "com.microsoft.teams", "messaging", "teams_personal_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"booking", "Booking.com", "com.booking", "travel", "booking_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"tripadvisor", "Tripadvisor", "com.tripadvisor.tripadvisor", "travel", "tripadvisor_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"viator", "Viator", "com.viator.mobile.android", "travel", "viator_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"stubhub", "StubHub", "com.stubhub", "travel", "stubhub_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"alltrails", "AllTrails", "com.alltrails.alltrails", "travel", "alltrails_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"taskrabbit", "Taskrabbit", "com.taskrabbit.droid.consumer", "services", "taskrabbit_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"thumbtack", "Thumbtack", "com.thumbtack.consumer", "services", "thumbtack_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"creditkarma", "Credit Karma", "com.creditkarma.mobile", "finance", "creditkarma_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"turbotax", "TurboTax", "com.intuit.turbotax.mobile", "finance", "turbotax_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"lyft", "Lyft", "me.lyft.android", "rides", "lyft_estimates_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"googlekeep", "Google Keep", "com.google.android.keep", "notes", "googlekeep_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		// Wave 1 messaging extras (class H compose hand-off; send rejected).
		{"whatsapp", "WhatsApp", "com.whatsapp", "messaging", "whatsapp_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"messenger", "Messenger", "com.facebook.orca", "messaging", "messenger_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"signal", "Signal", "org.thoughtcrime.securesms", "messaging", "signal_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		// Google Maps: one Spec, read (directions) + write (saved-place intent); never claim navigated/saved.
		{"googlemaps", "Google Maps", "com.google.android.apps.maps", "travel", "googlemaps_prepare_open_smoke", []manifest.Verb{manifest.Read, manifest.Write}},
		// Netflix: media play (search/open title) + write (My List intent); never claim played/added.
		{"netflix", "Netflix", "com.netflix.mediaclient", "media", "netflix_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Write}},
		// Facebook personal: messaging compose hand-off; never claim posted (no social class in stage1).
		{"facebook", "Facebook", "com.facebook.katana", "messaging", "facebook_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		// Airlines + Citymapper: travel/read only (flight status / manage-booking browse / transit); never book.
		{"united", "United", "com.united.mobile.android", "travel", "united_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"delta", "Delta", "com.delta.mobile.android", "travel", "delta_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Play Store id=com.southwestairlines.mobile (com.southwestair.mobile 404).
		{"southwest", "Southwest", "com.southwestairlines.mobile", "travel", "southwest_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"american", "American Airlines", "com.aa.android", "travel", "american_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"citymapper", "Citymapper", "com.citymapper.app.release", "travel", "citymapper_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// YouTube: media play|read; never claim played. Play Store id=com.google.android.youtube — HTTP 200.
		{"youtube", "YouTube", "com.google.android.youtube", "media", "youtube_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Read}},
		// Airbnb / OpenTable: travel|food read (Wave 3 book demoted); never claim booked. Play packages HTTP 200.
		{"airbnb", "Airbnb", "com.airbnb.android", "travel", "airbnb_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"opentable", "OpenTable", "com.opentable", "food", "opentable_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Grubhub: food read|order; never claim checkout completed. Play Store id=com.grubhub.android — HTTP 200.
		{"grubhub", "Grubhub", "com.grubhub.android", "food", "grubhub_prepare_open_smoke", []manifest.Verb{manifest.Read, manifest.Order}},
		// Threads / TikTok: messaging compose (Facebook peer; no stage1 social class); never claim posted/replied.
		{"threads", "Threads", "com.instagram.barcelona", "messaging", "threads_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		// TikTok: messaging compose (match Facebook; media ClassMap is play/read/write). Play id=com.zhiliaoapp.musically (com.ss.android.ugc.trill 404).
		{"tiktok", "TikTok", "com.zhiliaoapp.musically", "messaging", "tiktok_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		// Expedia: travel read (Wave 3 book demoted → read like Booking/Airbnb); never claim booked.
		{"expedia", "Expedia", "com.expedia.bookings", "travel", "expedia_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Shopping browse/open (Wave 3; no UCP cart API); read only — never claim cart/order/checkout.
		{"target", "Target", "com.target.ui", "shopping", "target_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"walmart", "Walmart", "com.walmart.android", "shopping", "walmart_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"nike", "Nike", "com.nike.omega", "shopping", "nike_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"sephora", "Sephora", "com.sephora", "shopping", "sephora_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"wayfair", "Wayfair", "com.wayfair.wayfair", "shopping", "wayfair_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"kayak", "Kayak", "com.kayak.android", "travel", "kayak_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Priceline / LinkedIn / eBay (Wave1Specs 51 → 54). Play packages HTTP 200 (2026-08-02).
		{"priceline", "Priceline", "com.priceline.android.negotiator", "travel", "priceline_search_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"linkedin", "LinkedIn", "com.linkedin.android", "messaging", "linkedin_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"ebay", "eBay", "com.ebay.mobile", "shopping", "ebay_browse_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
		// User ask: Wave1Specs 54 → 55 — Pinterest messaging compose; ProvesCeiling locked per Spec.
		{"pinterest", "Pinterest", "com.pinterest", "messaging", "pinterest_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		// Callers: Wave1Specs → runtime/deeplink, HandOffActions, stage1, deeplink_proof, this test.
		// User ask: Wave1Specs 55 → 58 — Duolingo/Fitbit services read + Shazam media read; ProvesCeiling locked.
		{"duolingo", "Duolingo", "com.duolingo", "services", "duolingo_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"fitbit", "Fitbit", "com.fitbit.FitbitMobile", "services", "fitbit_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"shazam", "Shazam", "com.shazam.android", "media", "shazam_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Callers: Wave1Specs → runtime/deeplink, HandOffActions, stage1, deeplink_proof, this test.
		// User ask: Wave1Specs 58 → 61 — Chromecast media play + YouTube Music/SoundCloud media play|read; ProvesCeiling locked.
		{"chromecast", "Chromecast", "com.google.android.apps.chromecast.app", "media", "chromecast_prepare_open_smoke", []manifest.Verb{manifest.Play}},
		{"youtubemusic", "YouTube Music", "com.google.android.apps.youtube.music", "media", "youtubemusic_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Read}},
		{"soundcloud", "SoundCloud", "com.soundcloud.android", "media", "soundcloud_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Read}},
		// Callers: Wave1Specs → runtime/deeplink, HandOffActions, stage1, deeplink_proof, this test.
		// User ask: Wave1Specs 61 → 64 — Pandora media play|read + Asana/Trello tasks write; ProvesCeiling locked.
		{"pandora", "Pandora", "com.pandora.android", "media", "pandora_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Read}},
		{"asana", "Asana", "com.asana.app", "tasks", "asana_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		{"trello", "Trello", "com.trello", "tasks", "trello_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		// Callers: Wave1Specs → runtime/deeplink, HandOffActions, stage1, deeplink_proof, this test.
		// User ask: Wave1Specs 64 → 67 — Microsoft To Do tasks write + Google Docs notes write + Dropbox notes read; ProvesCeiling locked.
		{"mstodo", "Microsoft To Do", "com.microsoft.todos", "tasks", "mstodo_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		{"googledocs", "Google Docs", "com.google.android.apps.docs.editors.docs", "notes", "googledocs_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		{"dropbox", "Dropbox", "com.dropbox.android", "notes", "dropbox_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Callers: Wave1Specs → runtime/deeplink, HandOffActions, stage1, deeplink_proof, this test.
		// User ask: Wave1Specs 67 → 70 — Google Sheets / Evernote / Google Slides notes write; ProvesCeiling locked.
		{"googlesheets", "Google Sheets", "com.google.android.apps.docs.editors.sheets", "notes", "googlesheets_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		{"evernote", "Evernote", "com.evernote", "notes", "evernote_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		{"googleslides", "Google Slides", "com.google.android.apps.docs.editors.slides", "notes", "googleslides_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		// Callers: Wave1Specs → runtime/deeplink, HandOffActions, stage1, deeplink_proof, this test.
		// User ask: Wave1Specs 70 → 73 — Pocket Casts media play|read + Goodreads notes read + Kindle media read; ProvesCeiling locked.
		// Pack goal: prepare-and-open only; never claim played/downloaded/subscribed (Pocket Casts), review posted/shelved/rated (Goodreads), purchased/downloaded/read completed (Kindle). Not Podcasts RT-2; not Amazon shopping.
		{"pocketcasts", "Pocket Casts", "au.com.shiftyjelly.pocketcasts", "media", "pocketcasts_prepare_open_smoke", []manifest.Verb{manifest.Play, manifest.Read}},
		{"goodreads", "Goodreads", "com.goodreads", "notes", "goodreads_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"kindle", "Kindle", "com.amazon.kindle", "media", "kindle_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		// Callers: Wave1Specs → runtime/deeplink, HandOffActions, stage1, deeplink_proof, this test.
		// User ask: Wave1Specs 73 → 76 — Claude/ChatGPT/Grok messaging compose; ProvesCeiling locked.
		// Pack goal: prepare-and-open draft prompt / open official apps only; never claim replied/sent/answered/completed chat. Operator does not call their APIs.
		{"claude", "Claude", "com.anthropic.claude", "messaging", "claude_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"chatgpt", "ChatGPT", "com.openai.chatgpt", "messaging", "chatgpt_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"grok", "Grok", "ai.x.grok", "messaging", "grok_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		// Wave1Specs 76 → 84; ids and destinations verified 2026-09-10.
		{"gmail", "Gmail", "com.google.android.gm", "messaging", "gmail_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"gcalendar", "Google Calendar", "com.google.android.calendar", "calendar", "gcalendar_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		{"slack", "Slack", "com.Slack", "slack", "slack_prepare_open_smoke", []manifest.Verb{manifest.Compose}},
		{"notion", "Notion", "notion.id", "notes", "notion_prepare_open_smoke", []manifest.Verb{manifest.Write}},
		{"waze", "Waze", "com.waze", "travel", "waze_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"zoom", "Zoom", "us.zoom.videomeetings", "services", "zoom_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"ticketmaster", "Ticketmaster", "com.ticketmaster.mobile.android.na", "travel", "ticketmaster_prepare_open_smoke", []manifest.Verb{manifest.Read}},
		{"instacart", "Instacart", "com.instacart.client", "food", "instacart_prepare_open_smoke", []manifest.Verb{manifest.Read}},
	}
	if len(Wave1Specs()) != len(want) {
		t.Fatalf("Wave1Specs count = %d, want %d", len(Wave1Specs()), len(want))
	}
	for i, spec := range Wave1Specs() {
		a := New(spec, logger)
		m := a.Describe()
		if err := m.Validate(); err != nil {
			t.Fatalf("%s manifest invalid: %v", spec.ID, err)
		}
		if m.ID != want[i].id || m.Runtime != manifest.RT4 || m.Ceiling != manifest.HandsOff {
			t.Fatalf("%s core = %+v", spec.ID, m)
		}
		if m.Auth != manifest.AuthNone || m.Consent != manifest.ConsentA || m.Platform != manifest.PlatformAndroid {
			t.Fatalf("%s auth/consent/platform = %+v", spec.ID, m)
		}
		if spec.AppClass != want[i].appClass {
			t.Fatalf("%s AppClass = %q, want %q", spec.ID, spec.AppClass, want[i].appClass)
		}
		if m.ProvesCeiling != want[i].proves {
			t.Fatalf("%s ProvesCeiling = %q, want %q", spec.ID, m.ProvesCeiling, want[i].proves)
		}
		for _, verb := range want[i].verbs {
			if !m.Allows(verb) {
				t.Fatalf("%s verbs = %v, missing %s", spec.ID, m.Verbs, verb)
			}
		}
		if m.Allows(manifest.Send) {
			t.Fatalf("%s must not allow send: %v", spec.ID, m.Verbs)
		}
		if a.AppName() != want[i].app || a.AndroidPackage() != want[i].pkg {
			t.Fatalf("%s app/package = %q/%q", spec.ID, a.AppName(), a.AndroidPackage())
		}
	}
}

func TestDeepLinkComposeHandsOffWithoutClaimingCompletion(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New()
	for _, spec := range Wave1Specs() {
		if err := reg.Register(New(spec, logger)); err != nil {
			t.Fatalf("register %s: %v", spec.ID, err)
		}
	}
	run := execution.New(reg)
	ctx := context.Background()

	cases := []struct {
		id, subject, body string
		verb              manifest.Verb
	}{
		{"venmo", "Maya", "$20 for dinner", manifest.Compose},
		{"cashapp", "Devansh", "$15 coffee", manifest.Compose},
		{"zelle", "Priya", "$40 rent share", manifest.Compose},
		{"starbucks", "usual", "grande oat latte", manifest.Order},
		{"chipotle", "bowl", "burrito bowl no rice", manifest.Order},
		{"spotify", "lofi beats", "play something calm while I work", manifest.Play},
		{"spotify", "Focus playlist", "add Rain Sounds to my Focus playlist", manifest.Write},
		{"audible", "Project Hail Mary", "continue Project Hail Mary from where I left off", manifest.Play},
		{"audible", "library", "find Atomic Habits in my Audible library", manifest.Read},
		{"applemusic", "lofi beats", "play something calm while I work", manifest.Play},
		{"applemusic", "Focus playlist", "add Rain Sounds to my Focus playlist", manifest.Write},
		{"messages", "Maya", "Running ten minutes late", manifest.Compose},
		{"discord", "Maya", "Running ten minutes late", manifest.Compose},
		{"uber", "airport", "fare estimate to SFO around 6pm", manifest.Read},
		{"ubereats", "Thai", "nearby Thai restaurants under $20", manifest.Read},
		{"resy", "Friday 7pm", "table for 2 at a quiet Italian place", manifest.Read},
		{"doordash", "burrito", "nearby burrito bowls for delivery", manifest.Read},
		{"doordash", "chipotle bowl", "chipotle bowl no rice for delivery", manifest.Order},
		{"googlephotos", "beach sunset", "find photos from last beach trip", manifest.Read},
		{"googlephotos", "album note", "save this trip note into Photos", manifest.Write},
		{"teams", "Maya", "Running ten minutes late", manifest.Compose},
		{"booking", "Lisbon", "hotels near Alfama under $150", manifest.Read},
		{"tripadvisor", "Rome", "best gelato near Trastevere", manifest.Read},
		{"viator", "Paris", "Louvre skip-the-line tour tomorrow", manifest.Read},
		{"stubhub", "Warriors", "Warriors tickets near me this weekend", manifest.Read},
		{"alltrails", "Yosemite", "moderate hikes near Yosemite Valley", manifest.Read},
		{"taskrabbit", "shelf", "assemble IKEA bookshelf this Saturday", manifest.Compose},
		{"thumbtack", "plumber", "find a plumber for a clogged sink", manifest.Compose},
		{"creditkarma", "score", "check my credit score and recent alerts", manifest.Read},
		{"turbotax", "2025 return", "open my 2025 tax return draft", manifest.Read},
		{"lyft", "airport", "fare estimate to SFO around 6pm", manifest.Read},
		{"googlekeep", "groceries", "milk eggs bread", manifest.Write},
		{"whatsapp", "Maya", "Running ten minutes late", manifest.Compose},
		{"messenger", "Maya", "Running ten minutes late", manifest.Compose},
		{"signal", "Maya", "Running ten minutes late", manifest.Compose},
		{"googlemaps", "SFO", "directions to SFO Terminal 2", manifest.Read},
		{"googlemaps", "home", "save home as a place in Maps", manifest.Write},
		{"netflix", "Stranger Things", "open Stranger Things on Netflix", manifest.Play},
		{"netflix", "My List", "add The Crown to My List", manifest.Write},
		{"facebook", "friends", "draft a post that I'm heading out", manifest.Compose},
		{"united", "UA123", "check flight status for UA123 tomorrow", manifest.Read},
		{"delta", "DL456", "open my Delta booking to manage seats", manifest.Read},
		{"southwest", "WN789", "check Southwest flight status for WN789", manifest.Read},
		{"american", "AA100", "open American Airlines to manage booking AA100", manifest.Read},
		{"citymapper", "home", "directions home on Citymapper", manifest.Read},
		{"youtube", "lofi beats", "open lofi beats on YouTube", manifest.Play},
		{"youtube", "search", "find cooking tutorials on YouTube", manifest.Read},
		{"airbnb", "Lisbon", "apartments near Alfama under $150", manifest.Read},
		{"opentable", "Friday 7pm", "table for 2 at a quiet Italian place", manifest.Read},
		{"grubhub", "burrito", "nearby burrito bowls for delivery", manifest.Read},
		{"grubhub", "chipotle bowl", "chipotle bowl no rice for delivery", manifest.Order},
		{"threads", "friends", "draft a Threads post that I'm heading out", manifest.Compose},
		{"tiktok", "friends", "draft a TikTok caption that I'm heading out", manifest.Compose},
		{"expedia", "Lisbon", "hotels near Alfama under $150", manifest.Read},
		{"target", "paper towels", "search paper towels nearby", manifest.Read},
		{"walmart", "groceries", "search milk and eggs", manifest.Read},
		{"nike", "running shoes", "search Pegasus running shoes", manifest.Read},
		{"sephora", "lipstick", "search lipstick nearby", manifest.Read},
		{"wayfair", "sofa", "search mid-century sofa", manifest.Read},
		{"kayak", "Lisbon", "flights to Lisbon next weekend", manifest.Read},
		{"priceline", "Miami", "hotels in Miami next weekend", manifest.Read},
		{"linkedin", "network", "draft a LinkedIn post that I'm open to work", manifest.Compose},
		{"ebay", "camera", "browse used cameras under $200", manifest.Read},
		// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
		// User ask: Pinterest messaging compose; never claim pinned/posted/saved.
		{"pinterest", "friends", "draft a Pinterest pin that I'm heading out", manifest.Compose},
		// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
		// User ask: Duolingo/Fitbit services read + Shazam media read; never claim lesson/workout/identified.
		{"duolingo", "Spanish", "open Spanish lesson A1 greetings", manifest.Read},
		{"fitbit", "today", "open today's activity summary", manifest.Read},
		{"shazam", "song", "identify this song nearby", manifest.Read},
		// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
		// User ask: Wave1Specs 58 → 61 — Chromecast play + YouTube Music/SoundCloud play|read; never claim cast/played/library.
		{"chromecast", "living room", "open Chromecast to cast living room TV", manifest.Play},
		{"youtubemusic", "lofi beats", "open lofi beats on YouTube Music", manifest.Play},
		{"youtubemusic", "search", "find cooking playlists on YouTube Music", manifest.Read},
		{"soundcloud", "lofi beats", "open lofi beats on SoundCloud", manifest.Play},
		{"soundcloud", "search", "find chill mixes on SoundCloud", manifest.Read},
		// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
		// User ask: Wave1Specs 61 → 64 — Pandora play|read + Asana/Trello write; never claim played/station/task/card.
		{"pandora", "lofi beats", "open lofi beats on Pandora", manifest.Play},
		{"pandora", "search", "find chill stations on Pandora", manifest.Read},
		{"asana", "groceries", "draft an Asana task to buy oat milk", manifest.Write},
		{"trello", "launch", "draft a Trello card for the launch checklist", manifest.Write},
		// User ask: Wave1Specs 64 → 67 — mstodo write + googledocs write + dropbox read; never claim task/doc/file completion.
		{"mstodo", "groceries", "draft a Microsoft To Do task to buy oat milk", manifest.Write},
		{"googledocs", "meeting notes", "draft a Google Doc for meeting notes", manifest.Write},
		{"dropbox", "receipts", "open receipts folder in Dropbox", manifest.Read},
		// User ask: Wave1Specs 67 → 70 — googlesheets/evernote/googleslides write; never claim sheet/notebook/slide completion.
		{"googlesheets", "budget", "draft a Google Sheet for Q3 budget", manifest.Write},
		{"evernote", "meeting notes", "draft an Evernote note for meeting notes", manifest.Write},
		{"googleslides", "pitch", "draft a Google Slides deck for the pitch", manifest.Write},
		// User ask: Wave1Specs 70 → 73 — pocketcasts play|read + goodreads read + kindle read; never claim played/subscribed/shelved/rated/purchased.
		{"pocketcasts", "This American Life", "open This American Life on Pocket Casts", manifest.Play},
		{"pocketcasts", "search", "find tech podcasts on Pocket Casts", manifest.Read},
		{"goodreads", "Project Hail Mary", "open Project Hail Mary on Goodreads", manifest.Read},
		{"kindle", "library", "open my Kindle library", manifest.Read},
		// User ask: Wave1Specs 73 → 76 — claude/chatgpt/grok compose; never claim replied/sent/answered/completed chat.
		{"claude", "prompt", "draft a Claude prompt about weekend plans", manifest.Compose},
		{"chatgpt", "prompt", "draft a ChatGPT prompt about weekend plans", manifest.Compose},
		{"grok", "prompt", "draft a Grok prompt about weekend plans", manifest.Compose},
		{"gmail", "Maya", "draft a reply saying I will send the deck tonight", manifest.Compose},
		{"gcalendar", "Design review", "hold 30 minutes Thursday afternoon", manifest.Write},
		{"slack", "#design", "draft a note that the build is green", manifest.Compose},
		{"notion", "Weekly notes", "start a page for this week's notes", manifest.Write},
		{"waze", "home", "drive home avoiding tolls", manifest.Read},
		{"zoom", "standup", "open my next meeting", manifest.Read},
		{"ticketmaster", "Chicago Symphony", "tickets for a Saturday performance", manifest.Read},
		{"instacart", "oat milk", "nearby stores carrying oat milk", manifest.Read},
	}
	for _, tc := range cases {
		t.Run(tc.id+"/"+string(tc.verb), func(t *testing.T) {
			plan, err := run.Resolve(ctx, adapter.Intent{
				AdapterID: tc.id, Verb: tc.verb, Subject: tc.subject, Body: tc.body,
			})
			if err != nil {
				t.Fatalf("resolve: %v", err)
			}
			if plan.Details["draft"] != tc.body {
				t.Fatalf("draft = %q", plan.Details["draft"])
			}
			if plan.Details["android_package"] == "" {
				t.Fatal("missing android_package")
			}
			preview, err := run.Preview(ctx, plan)
			if err != nil {
				t.Fatalf("preview: %v", err)
			}
			shown := preview.Headline + " " + strings.Join(preview.Lines, " ")
			if !strings.Contains(shown, tc.body) {
				t.Fatalf("preview missing draft: %q", shown)
			}
			out, err := run.Execute(ctx, plan, preview.Confirmed())
			if err != nil {
				t.Fatalf("execute: %v", err)
			}
			if out.Reached != manifest.HandsOff || !out.Done {
				t.Fatalf("outcome = %+v", out)
			}
			lower := strings.ToLower(out.Detail + " " + out.HandedOffTo)
			// Shared execute ban list: DraftOutcome must never claim completion.
			// Callers: judge hardening; expand keeps existing bans + cart/checkout/purchase/social claims.
			for _, bad := range []string{
				"sent", "paid", "ordered", "completed payment", "played", "playing", "started playback",
				"added to playlist", "booked", "reserved", "ride requested",
				"cart built", "checkout completed", "purchased", "bought", "bid placed",
				"posted", "commented", "watched", "ticketed", "pinned", "saved", "published",
				// Callers: Duolingo/Fitbit/Shazam pack; never claim lesson/workout/identify completion.
				"lesson completed", "workout logged", "synced", "identified",
				// Callers: Chromecast/YouTube Music/SoundCloud pack; never claim cast/library completion.
				"cast started", "connected", "library changed",
				// Callers: Pandora/Asana/Trello pack; never claim station/task/card completion.
				// Judge residual: also ban bare "completed" and "card created".
				"station changed", "task created", "card moved", "assigned", "completed", "card created",
				// Callers: Microsoft To Do / Google Docs / Dropbox pack; never claim upload/download/share/doc completion.
				// Judge residual: also ban "doc created" / "doc saved".
				"uploaded", "downloaded", "shared", "doc created", "doc saved",
				// Callers: Google Sheets / Evernote / Google Slides pack; never claim sheet/notebook/slide creation.
				"sheet created", "slide created", "notebook created",
				// Callers: Pocket Casts / Goodreads / Kindle pack; never claim subscribe/shelf/rate completion.
				"subscribed", "shelved", "rated",
				// Callers: Claude / ChatGPT / Grok pack; never claim chat reply/answer completion.
				"replied", "answered",
			} {
				if strings.Contains(lower, bad) {
					t.Fatalf("detail claims completion (%q): %q", bad, out.Detail)
				}
			}
			if !strings.Contains(strings.ToLower(out.Detail), "cannot know") {
				t.Fatalf("detail must say Operator cannot know: %q", out.Detail)
			}
		})
	}
}

func TestDeepLinkRejectsEmptyDraftAndWrongVerb(t *testing.T) {
	a := New(Wave1Specs()[0], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err := a.Resolve(context.Background(), adapter.Intent{
		AdapterID: "venmo", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("empty draft err = %v", err)
	}
	_, err = a.Resolve(context.Background(), adapter.Intent{
		AdapterID: "venmo", Verb: manifest.Send, Body: "$20",
	})
	if err == nil {
		t.Fatal("send was accepted on a money hand-off adapter")
	}
	spotify := New(Wave1Specs()[5], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = spotify.Resolve(context.Background(), adapter.Intent{
		AdapterID: "spotify", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("spotify empty draft err = %v", err)
	}
	_, err = spotify.Resolve(context.Background(), adapter.Intent{
		AdapterID: "spotify", Verb: manifest.Send, Body: "play lofi",
	})
	if err == nil {
		t.Fatal("send was accepted on Spotify prepare-and-open adapter")
	}
	audible := New(Wave1Specs()[6], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = audible.Resolve(context.Background(), adapter.Intent{
		AdapterID: "audible", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("audible empty draft err = %v", err)
	}
	_, err = audible.Resolve(context.Background(), adapter.Intent{
		AdapterID: "audible", Verb: manifest.Send, Body: "continue Hail Mary",
	})
	if err == nil {
		t.Fatal("send was accepted on Audible prepare-and-open adapter")
	}
	applemusic := New(Wave1Specs()[7], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = applemusic.Resolve(context.Background(), adapter.Intent{
		AdapterID: "applemusic", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("applemusic empty draft err = %v", err)
	}
	_, err = applemusic.Resolve(context.Background(), adapter.Intent{
		AdapterID: "applemusic", Verb: manifest.Send, Body: "play lofi",
	})
	if err == nil {
		t.Fatal("send was accepted on Apple Music prepare-and-open adapter")
	}
	messages := New(Wave1Specs()[8], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = messages.Resolve(context.Background(), adapter.Intent{
		AdapterID: "messages", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("messages empty draft err = %v", err)
	}
	_, err = messages.Resolve(context.Background(), adapter.Intent{
		AdapterID: "messages", Verb: manifest.Send, Body: "Running ten minutes late",
	})
	if err == nil {
		t.Fatal("send was accepted on Messages prepare-and-open adapter")
	}
	discord := New(Wave1Specs()[9], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = discord.Resolve(context.Background(), adapter.Intent{
		AdapterID: "discord", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("discord empty draft err = %v", err)
	}
	_, err = discord.Resolve(context.Background(), adapter.Intent{
		AdapterID: "discord", Verb: manifest.Send, Body: "Running ten minutes late",
	})
	if err == nil {
		t.Fatal("send was accepted on Discord prepare-and-open adapter")
	}
	uber := New(Wave1Specs()[10], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = uber.Resolve(context.Background(), adapter.Intent{
		AdapterID: "uber", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("uber empty draft err = %v", err)
	}
	_, err = uber.Resolve(context.Background(), adapter.Intent{
		AdapterID: "uber", Verb: manifest.Book, Body: "ride to SFO",
	})
	if err == nil {
		t.Fatal("book was accepted on Uber estimates prepare-and-open adapter")
	}
	// Callers: deeplink adapter_test. Judge gap: Eats/Resy wrong-verb rejects.
	// User: follow-up on rides/food judge — add order/book reject tests.
	ubereats := New(Wave1Specs()[11], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = ubereats.Resolve(context.Background(), adapter.Intent{
		AdapterID: "ubereats", Verb: manifest.Order, Body: "pad thai",
	})
	if err == nil {
		t.Fatal("order was accepted on Uber Eats read-only prepare-and-open adapter")
	}
	resy := New(Wave1Specs()[12], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = resy.Resolve(context.Background(), adapter.Intent{
		AdapterID: "resy", Verb: manifest.Book, Body: "table for 2 Friday",
	})
	if err == nil {
		t.Fatal("book was accepted on Resy read-only prepare-and-open adapter")
	}
	doordash := New(Wave1Specs()[13], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = doordash.Resolve(context.Background(), adapter.Intent{
		AdapterID: "doordash", Verb: manifest.Order, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("doordash empty draft err = %v", err)
	}
	_, err = doordash.Resolve(context.Background(), adapter.Intent{
		AdapterID: "doordash", Verb: manifest.Send, Body: "burrito bowl",
	})
	if err == nil {
		t.Fatal("send was accepted on DoorDash prepare-and-open adapter")
	}
	googlephotos := New(Wave1Specs()[14], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = googlephotos.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlephotos", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("googlephotos empty draft err = %v", err)
	}
	_, err = googlephotos.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlephotos", Verb: manifest.Send, Body: "find beach photos",
	})
	if err == nil {
		t.Fatal("send was accepted on Google Photos prepare-and-open adapter")
	}
	teams := New(Wave1Specs()[15], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = teams.Resolve(context.Background(), adapter.Intent{
		AdapterID: "teams", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("teams empty draft err = %v", err)
	}
	_, err = teams.Resolve(context.Background(), adapter.Intent{
		AdapterID: "teams", Verb: manifest.Send, Body: "Running ten minutes late",
	})
	if err == nil {
		t.Fatal("send was accepted on Teams prepare-and-open adapter")
	}
	booking := New(Wave1Specs()[16], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = booking.Resolve(context.Background(), adapter.Intent{
		AdapterID: "booking", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("booking empty draft err = %v", err)
	}
	_, err = booking.Resolve(context.Background(), adapter.Intent{
		AdapterID: "booking", Verb: manifest.Book, Body: "hotel in Lisbon",
	})
	if err == nil {
		t.Fatal("book was accepted on Booking.com prepare-and-open adapter")
	}
	for i, id := range []string{"tripadvisor", "viator", "stubhub", "alltrails"} {
		travel := New(Wave1Specs()[17+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = travel.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Read, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = travel.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Book, Body: "book something",
		})
		if err == nil {
			t.Fatalf("book was accepted on %s prepare-and-open adapter", id)
		}
		_, err = travel.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "search something",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
	}
	for i, id := range []string{"taskrabbit", "thumbtack"} {
		services := New(Wave1Specs()[21+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = services.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Compose, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = services.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "assemble shelf",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
		_, err = services.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Book, Body: "book a tasker",
		})
		if err == nil {
			t.Fatalf("book was accepted on %s prepare-and-open adapter", id)
		}
		_, err = services.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Order, Body: "order a tasker",
		})
		if err == nil {
			t.Fatalf("order was accepted on %s prepare-and-open adapter", id)
		}
	}
	for i, id := range []string{"creditkarma", "turbotax"} {
		finance := New(Wave1Specs()[23+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = finance.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Read, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = finance.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "check score",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
		_, err = finance.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Book, Body: "file return",
		})
		if err == nil {
			t.Fatalf("book was accepted on %s prepare-and-open adapter", id)
		}
		_, err = finance.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Order, Body: "order report",
		})
		if err == nil {
			t.Fatalf("order was accepted on %s prepare-and-open adapter", id)
		}
	}
	lyft := New(Wave1Specs()[25], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = lyft.Resolve(context.Background(), adapter.Intent{
		AdapterID: "lyft", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("lyft empty draft err = %v", err)
	}
	_, err = lyft.Resolve(context.Background(), adapter.Intent{
		AdapterID: "lyft", Verb: manifest.Book, Body: "ride to SFO",
	})
	if err == nil {
		t.Fatal("book was accepted on Lyft estimates prepare-and-open adapter")
	}
	googlekeep := New(Wave1Specs()[26], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = googlekeep.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlekeep", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("googlekeep empty draft err = %v", err)
	}
	_, err = googlekeep.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlekeep", Verb: manifest.Send, Body: "milk eggs bread",
	})
	if err == nil {
		t.Fatal("send was accepted on Google Keep prepare-and-open adapter")
	}
	// Messaging extras: WhatsApp / Messenger / Signal — compose only; never send.
	// Notification reply is a separate ReplyCapability path (not this adapter).
	for i, id := range []string{"whatsapp", "messenger", "signal"} {
		msg := New(Wave1Specs()[27+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = msg.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Compose, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = msg.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "Running ten minutes late",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
	}
	// Google Maps: travel read|write hand-off; never send/book/navigate completion.
	googlemaps := New(Wave1Specs()[30], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = googlemaps.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlemaps", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("googlemaps empty draft err = %v", err)
	}
	_, err = googlemaps.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlemaps", Verb: manifest.Send, Body: "directions to SFO",
	})
	if err == nil {
		t.Fatal("send was accepted on Google Maps prepare-and-open adapter")
	}
	_, err = googlemaps.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlemaps", Verb: manifest.Book, Body: "navigate to home",
	})
	if err == nil {
		t.Fatal("book was accepted on Google Maps prepare-and-open adapter")
	}
	// Netflix: media play|write; never send/empty. Never claim played/added to list.
	netflix := New(Wave1Specs()[31], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = netflix.Resolve(context.Background(), adapter.Intent{
		AdapterID: "netflix", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("netflix empty draft err = %v", err)
	}
	_, err = netflix.Resolve(context.Background(), adapter.Intent{
		AdapterID: "netflix", Verb: manifest.Send, Body: "open Stranger Things",
	})
	if err == nil {
		t.Fatal("send was accepted on Netflix prepare-and-open adapter")
	}
	// Facebook personal: messaging compose only; never send/posted.
	facebook := New(Wave1Specs()[32], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = facebook.Resolve(context.Background(), adapter.Intent{
		AdapterID: "facebook", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("facebook empty draft err = %v", err)
	}
	_, err = facebook.Resolve(context.Background(), adapter.Intent{
		AdapterID: "facebook", Verb: manifest.Send, Body: "draft a post that I'm heading out",
	})
	if err == nil {
		t.Fatal("send was accepted on Facebook prepare-and-open adapter")
	}
	// Airlines + Citymapper: travel/read only; never book/send/empty; never claim booked/checked-in/boarded.
	for i, id := range []string{"united", "delta", "southwest", "american", "citymapper"} {
		airline := New(Wave1Specs()[33+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = airline.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Read, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = airline.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Book, Body: "book a flight",
		})
		if err == nil {
			t.Fatalf("book was accepted on %s prepare-and-open adapter", id)
		}
		_, err = airline.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "check flight status",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
	}
	// YouTube: media play|read; never send/empty. Never claim played.
	youtube := New(Wave1Specs()[38], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = youtube.Resolve(context.Background(), adapter.Intent{
		AdapterID: "youtube", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("youtube empty draft err = %v", err)
	}
	_, err = youtube.Resolve(context.Background(), adapter.Intent{
		AdapterID: "youtube", Verb: manifest.Send, Body: "open lofi beats",
	})
	if err == nil {
		t.Fatal("send was accepted on YouTube prepare-and-open adapter")
	}
	// Airbnb / OpenTable: travel|food read; never book/send/empty (Wave 3 book demoted).
	for i, id := range []string{"airbnb", "opentable"} {
		app := New(Wave1Specs()[39+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = app.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Read, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = app.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Book, Body: "book a reservation",
		})
		if err == nil {
			t.Fatalf("book was accepted on %s prepare-and-open adapter", id)
		}
		_, err = app.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "search availability",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
	}
	// Grubhub: food read|order; never send/empty. Never claim checkout completed.
	grubhub := New(Wave1Specs()[41], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = grubhub.Resolve(context.Background(), adapter.Intent{
		AdapterID: "grubhub", Verb: manifest.Order, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("grubhub empty draft err = %v", err)
	}
	_, err = grubhub.Resolve(context.Background(), adapter.Intent{
		AdapterID: "grubhub", Verb: manifest.Book, Body: "book delivery",
	})
	if err == nil {
		t.Fatal("book was accepted on Grubhub prepare-and-open adapter")
	}
	_, err = grubhub.Resolve(context.Background(), adapter.Intent{
		AdapterID: "grubhub", Verb: manifest.Send, Body: "burrito bowl",
	})
	if err == nil {
		t.Fatal("send was accepted on Grubhub prepare-and-open adapter")
	}
	// Threads / TikTok: messaging compose; never send/empty. Never claim posted/replied.
	for i, id := range []string{"threads", "tiktok"} {
		app := New(Wave1Specs()[42+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = app.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Compose, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = app.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "draft a post that I'm heading out",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
	}
	// Expedia: travel read; never book/send/empty. Never claim booked.
	expedia := New(Wave1Specs()[44], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = expedia.Resolve(context.Background(), adapter.Intent{
		AdapterID: "expedia", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("expedia empty draft err = %v", err)
	}
	_, err = expedia.Resolve(context.Background(), adapter.Intent{
		AdapterID: "expedia", Verb: manifest.Book, Body: "book hotel in Lisbon",
	})
	if err == nil {
		t.Fatal("book was accepted on Expedia prepare-and-open adapter")
	}
	_, err = expedia.Resolve(context.Background(), adapter.Intent{
		AdapterID: "expedia", Verb: manifest.Send, Body: "hotels near Alfama",
	})
	if err == nil {
		t.Fatal("send was accepted on Expedia prepare-and-open adapter")
	}
	// Shopping (Target/Walmart/Nike/Sephora/Wayfair + eBay at index 53): read browse/open;
	// never order/book/send/empty. Never claim cart built, ordered, bid placed, or checkout.
	for i, id := range []string{"target", "walmart", "nike", "sephora", "wayfair"} {
		shop := New(Wave1Specs()[45+i], slog.New(slog.NewTextHandler(io.Discard, nil)))
		_, err = shop.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Read, Body: "  ",
		})
		if !errors.Is(err, ErrEmptyDraft) {
			t.Fatalf("%s empty draft err = %v", id, err)
		}
		_, err = shop.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Order, Body: "add paper towels to cart",
		})
		if err == nil {
			t.Fatalf("order was accepted on %s prepare-and-open adapter", id)
		}
		_, err = shop.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Book, Body: "buy running shoes",
		})
		if err == nil {
			t.Fatalf("book was accepted on %s prepare-and-open adapter", id)
		}
		_, err = shop.Resolve(context.Background(), adapter.Intent{
			AdapterID: id, Verb: manifest.Send, Body: "search paper towels",
		})
		if err == nil {
			t.Fatalf("send was accepted on %s prepare-and-open adapter", id)
		}
	}
	// Kayak: travel read; never book/send/empty. Never claim booked.
	kayak := New(Wave1Specs()[50], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = kayak.Resolve(context.Background(), adapter.Intent{
		AdapterID: "kayak", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("kayak empty draft err = %v", err)
	}
	_, err = kayak.Resolve(context.Background(), adapter.Intent{
		AdapterID: "kayak", Verb: manifest.Book, Body: "book flight to Lisbon",
	})
	if err == nil {
		t.Fatal("book was accepted on Kayak prepare-and-open adapter")
	}
	_, err = kayak.Resolve(context.Background(), adapter.Intent{
		AdapterID: "kayak", Verb: manifest.Send, Body: "flights to Lisbon",
	})
	if err == nil {
		t.Fatal("send was accepted on Kayak prepare-and-open adapter")
	}
	// Priceline: travel read; never book/send/empty. Never claim booked.
	priceline := New(Wave1Specs()[51], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = priceline.Resolve(context.Background(), adapter.Intent{
		AdapterID: "priceline", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("priceline empty draft err = %v", err)
	}
	_, err = priceline.Resolve(context.Background(), adapter.Intent{
		AdapterID: "priceline", Verb: manifest.Book, Body: "book hotel in Miami",
	})
	if err == nil {
		t.Fatal("book was accepted on Priceline prepare-and-open adapter")
	}
	_, err = priceline.Resolve(context.Background(), adapter.Intent{
		AdapterID: "priceline", Verb: manifest.Send, Body: "hotels in Miami",
	})
	if err == nil {
		t.Fatal("send was accepted on Priceline prepare-and-open adapter")
	}
	// LinkedIn: messaging compose (Facebook/Threads peer); never send/empty. Never claim posted/commented.
	linkedin := New(Wave1Specs()[52], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = linkedin.Resolve(context.Background(), adapter.Intent{
		AdapterID: "linkedin", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("linkedin empty draft err = %v", err)
	}
	_, err = linkedin.Resolve(context.Background(), adapter.Intent{
		AdapterID: "linkedin", Verb: manifest.Send, Body: "draft a LinkedIn post",
	})
	if err == nil {
		t.Fatal("send was accepted on LinkedIn prepare-and-open adapter")
	}
	// eBay: shopping read browse/open; never order/book/send/empty. Never claim cart/bid/checkout.
	ebay := New(Wave1Specs()[53], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = ebay.Resolve(context.Background(), adapter.Intent{
		AdapterID: "ebay", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("ebay empty draft err = %v", err)
	}
	_, err = ebay.Resolve(context.Background(), adapter.Intent{
		AdapterID: "ebay", Verb: manifest.Order, Body: "add camera to cart",
	})
	if err == nil {
		t.Fatal("order was accepted on eBay prepare-and-open adapter")
	}
	_, err = ebay.Resolve(context.Background(), adapter.Intent{
		AdapterID: "ebay", Verb: manifest.Book, Body: "place bid on camera",
	})
	if err == nil {
		t.Fatal("book was accepted on eBay prepare-and-open adapter")
	}
	_, err = ebay.Resolve(context.Background(), adapter.Intent{
		AdapterID: "ebay", Verb: manifest.Send, Body: "browse used cameras",
	})
	if err == nil {
		t.Fatal("send was accepted on eBay prepare-and-open adapter")
	}
	// Pinterest: messaging compose (Facebook/Threads peer); never send/empty. Never claim pinned/posted/saved.
	pinterest := New(Wave1Specs()[54], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = pinterest.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pinterest", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("pinterest empty draft err = %v", err)
	}
	_, err = pinterest.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pinterest", Verb: manifest.Send, Body: "draft a Pinterest pin that I'm heading out",
	})
	if err == nil {
		t.Fatal("send was accepted on Pinterest prepare-and-open adapter")
	}
	// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
	// User ask: Wave1Specs 55 → 58 — Duolingo/Fitbit services read + Shazam media read reject empty/wrong verb.
	duolingo := New(Wave1Specs()[55], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = duolingo.Resolve(context.Background(), adapter.Intent{
		AdapterID: "duolingo", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("duolingo empty draft err = %v", err)
	}
	_, err = duolingo.Resolve(context.Background(), adapter.Intent{
		AdapterID: "duolingo", Verb: manifest.Compose, Body: "open Spanish lesson A1 greetings",
	})
	if err == nil {
		t.Fatal("compose was accepted on Duolingo prepare-and-open adapter")
	}
	_, err = duolingo.Resolve(context.Background(), adapter.Intent{
		AdapterID: "duolingo", Verb: manifest.Send, Body: "open Spanish lesson A1 greetings",
	})
	if err == nil {
		t.Fatal("send was accepted on Duolingo prepare-and-open adapter")
	}
	fitbit := New(Wave1Specs()[56], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = fitbit.Resolve(context.Background(), adapter.Intent{
		AdapterID: "fitbit", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("fitbit empty draft err = %v", err)
	}
	_, err = fitbit.Resolve(context.Background(), adapter.Intent{
		AdapterID: "fitbit", Verb: manifest.Write, Body: "log a workout",
	})
	if err == nil {
		t.Fatal("write was accepted on Fitbit prepare-and-open adapter")
	}
	_, err = fitbit.Resolve(context.Background(), adapter.Intent{
		AdapterID: "fitbit", Verb: manifest.Send, Body: "open today's activity summary",
	})
	if err == nil {
		t.Fatal("send was accepted on Fitbit prepare-and-open adapter")
	}
	shazam := New(Wave1Specs()[57], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = shazam.Resolve(context.Background(), adapter.Intent{
		AdapterID: "shazam", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("shazam empty draft err = %v", err)
	}
	_, err = shazam.Resolve(context.Background(), adapter.Intent{
		AdapterID: "shazam", Verb: manifest.Play, Body: "identify this song nearby",
	})
	if err == nil {
		t.Fatal("play was accepted on Shazam prepare-and-open adapter")
	}
	_, err = shazam.Resolve(context.Background(), adapter.Intent{
		AdapterID: "shazam", Verb: manifest.Send, Body: "identify this song nearby",
	})
	if err == nil {
		t.Fatal("send was accepted on Shazam prepare-and-open adapter")
	}
	// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
	// User ask: Wave1Specs 58 → 61 — Chromecast play + YouTube Music/SoundCloud play|read reject empty/wrong verb.
	chromecast := New(Wave1Specs()[58], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = chromecast.Resolve(context.Background(), adapter.Intent{
		AdapterID: "chromecast", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("chromecast empty draft err = %v", err)
	}
	_, err = chromecast.Resolve(context.Background(), adapter.Intent{
		AdapterID: "chromecast", Verb: manifest.Read, Body: "open Chromecast to cast living room TV",
	})
	if err == nil {
		t.Fatal("read was accepted on Chromecast prepare-and-open adapter")
	}
	_, err = chromecast.Resolve(context.Background(), adapter.Intent{
		AdapterID: "chromecast", Verb: manifest.Send, Body: "open Chromecast to cast living room TV",
	})
	if err == nil {
		t.Fatal("send was accepted on Chromecast prepare-and-open adapter")
	}
	youtubemusic := New(Wave1Specs()[59], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = youtubemusic.Resolve(context.Background(), adapter.Intent{
		AdapterID: "youtubemusic", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("youtubemusic empty draft err = %v", err)
	}
	_, err = youtubemusic.Resolve(context.Background(), adapter.Intent{
		AdapterID: "youtubemusic", Verb: manifest.Write, Body: "add Rain Sounds to my library",
	})
	if err == nil {
		t.Fatal("write was accepted on YouTube Music prepare-and-open adapter")
	}
	_, err = youtubemusic.Resolve(context.Background(), adapter.Intent{
		AdapterID: "youtubemusic", Verb: manifest.Send, Body: "open lofi beats on YouTube Music",
	})
	if err == nil {
		t.Fatal("send was accepted on YouTube Music prepare-and-open adapter")
	}
	soundcloud := New(Wave1Specs()[60], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = soundcloud.Resolve(context.Background(), adapter.Intent{
		AdapterID: "soundcloud", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("soundcloud empty draft err = %v", err)
	}
	_, err = soundcloud.Resolve(context.Background(), adapter.Intent{
		AdapterID: "soundcloud", Verb: manifest.Write, Body: "add Rain Sounds to my library",
	})
	if err == nil {
		t.Fatal("write was accepted on SoundCloud prepare-and-open adapter")
	}
	_, err = soundcloud.Resolve(context.Background(), adapter.Intent{
		AdapterID: "soundcloud", Verb: manifest.Send, Body: "open lofi beats on SoundCloud",
	})
	if err == nil {
		t.Fatal("send was accepted on SoundCloud prepare-and-open adapter")
	}
	// Callers: go test ./companion/internal/capability/adapters/deeplink/ (this file).
	// User ask: Wave1Specs 61 → 64 — Pandora play|read + Asana/Trello write reject empty/wrong verb.
	pandora := New(Wave1Specs()[61], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = pandora.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pandora", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("pandora empty draft err = %v", err)
	}
	_, err = pandora.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pandora", Verb: manifest.Write, Body: "add Rain Sounds to my station",
	})
	if err == nil {
		t.Fatal("write was accepted on Pandora prepare-and-open adapter")
	}
	_, err = pandora.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pandora", Verb: manifest.Send, Body: "open lofi beats on Pandora",
	})
	if err == nil {
		t.Fatal("send was accepted on Pandora prepare-and-open adapter")
	}
	asana := New(Wave1Specs()[62], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = asana.Resolve(context.Background(), adapter.Intent{
		AdapterID: "asana", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("asana empty draft err = %v", err)
	}
	_, err = asana.Resolve(context.Background(), adapter.Intent{
		AdapterID: "asana", Verb: manifest.Send, Body: "draft an Asana task to buy oat milk",
	})
	if err == nil {
		t.Fatal("send was accepted on Asana prepare-and-open adapter")
	}
	_, err = asana.Resolve(context.Background(), adapter.Intent{
		AdapterID: "asana", Verb: manifest.Compose, Body: "draft an Asana task to buy oat milk",
	})
	if err == nil {
		t.Fatal("compose was accepted on Asana prepare-and-open adapter")
	}
	trello := New(Wave1Specs()[63], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = trello.Resolve(context.Background(), adapter.Intent{
		AdapterID: "trello", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("trello empty draft err = %v", err)
	}
	_, err = trello.Resolve(context.Background(), adapter.Intent{
		AdapterID: "trello", Verb: manifest.Send, Body: "draft a Trello card for the launch checklist",
	})
	if err == nil {
		t.Fatal("send was accepted on Trello prepare-and-open adapter")
	}
	_, err = trello.Resolve(context.Background(), adapter.Intent{
		AdapterID: "trello", Verb: manifest.Compose, Body: "draft a Trello card for the launch checklist",
	})
	if err == nil {
		t.Fatal("compose was accepted on Trello prepare-and-open adapter")
	}
	// User ask: Wave1Specs 64 → 67 — mstodo write + googledocs write + dropbox read reject empty/wrong verb.
	mstodo := New(Wave1Specs()[64], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = mstodo.Resolve(context.Background(), adapter.Intent{
		AdapterID: "mstodo", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("mstodo empty draft err = %v", err)
	}
	_, err = mstodo.Resolve(context.Background(), adapter.Intent{
		AdapterID: "mstodo", Verb: manifest.Send, Body: "draft a Microsoft To Do task to buy oat milk",
	})
	if err == nil {
		t.Fatal("send was accepted on Microsoft To Do prepare-and-open adapter")
	}
	_, err = mstodo.Resolve(context.Background(), adapter.Intent{
		AdapterID: "mstodo", Verb: manifest.Compose, Body: "draft a Microsoft To Do task to buy oat milk",
	})
	if err == nil {
		t.Fatal("compose was accepted on Microsoft To Do prepare-and-open adapter")
	}
	googledocs := New(Wave1Specs()[65], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = googledocs.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googledocs", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("googledocs empty draft err = %v", err)
	}
	_, err = googledocs.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googledocs", Verb: manifest.Send, Body: "draft a Google Doc for meeting notes",
	})
	if err == nil {
		t.Fatal("send was accepted on Google Docs prepare-and-open adapter")
	}
	_, err = googledocs.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googledocs", Verb: manifest.Read, Body: "draft a Google Doc for meeting notes",
	})
	if err == nil {
		t.Fatal("read was accepted on Google Docs prepare-and-open adapter")
	}
	dropbox := New(Wave1Specs()[66], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = dropbox.Resolve(context.Background(), adapter.Intent{
		AdapterID: "dropbox", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("dropbox empty draft err = %v", err)
	}
	_, err = dropbox.Resolve(context.Background(), adapter.Intent{
		AdapterID: "dropbox", Verb: manifest.Write, Body: "open receipts folder in Dropbox",
	})
	if err == nil {
		t.Fatal("write was accepted on Dropbox prepare-and-open adapter")
	}
	_, err = dropbox.Resolve(context.Background(), adapter.Intent{
		AdapterID: "dropbox", Verb: manifest.Send, Body: "open receipts folder in Dropbox",
	})
	if err == nil {
		t.Fatal("send was accepted on Dropbox prepare-and-open adapter")
	}
	// User ask: Wave1Specs 67 → 70 — googlesheets/evernote/googleslides write reject empty/wrong verb.
	googlesheets := New(Wave1Specs()[67], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = googlesheets.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlesheets", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("googlesheets empty draft err = %v", err)
	}
	_, err = googlesheets.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlesheets", Verb: manifest.Send, Body: "draft a Google Sheet for Q3 budget",
	})
	if err == nil {
		t.Fatal("send was accepted on Google Sheets prepare-and-open adapter")
	}
	_, err = googlesheets.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googlesheets", Verb: manifest.Read, Body: "draft a Google Sheet for Q3 budget",
	})
	if err == nil {
		t.Fatal("read was accepted on Google Sheets prepare-and-open adapter")
	}
	evernote := New(Wave1Specs()[68], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = evernote.Resolve(context.Background(), adapter.Intent{
		AdapterID: "evernote", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("evernote empty draft err = %v", err)
	}
	_, err = evernote.Resolve(context.Background(), adapter.Intent{
		AdapterID: "evernote", Verb: manifest.Send, Body: "draft an Evernote note for meeting notes",
	})
	if err == nil {
		t.Fatal("send was accepted on Evernote prepare-and-open adapter")
	}
	_, err = evernote.Resolve(context.Background(), adapter.Intent{
		AdapterID: "evernote", Verb: manifest.Read, Body: "draft an Evernote note for meeting notes",
	})
	if err == nil {
		t.Fatal("read was accepted on Evernote prepare-and-open adapter")
	}
	googleslides := New(Wave1Specs()[69], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = googleslides.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googleslides", Verb: manifest.Write, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("googleslides empty draft err = %v", err)
	}
	_, err = googleslides.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googleslides", Verb: manifest.Send, Body: "draft a Google Slides deck for the pitch",
	})
	if err == nil {
		t.Fatal("send was accepted on Google Slides prepare-and-open adapter")
	}
	_, err = googleslides.Resolve(context.Background(), adapter.Intent{
		AdapterID: "googleslides", Verb: manifest.Read, Body: "draft a Google Slides deck for the pitch",
	})
	if err == nil {
		t.Fatal("read was accepted on Google Slides prepare-and-open adapter")
	}
	// Callers: Wave1Specs → adapters/deeplink reject tests (this file).
	// User ask: Wave1Specs 70 → 73 — pocketcasts play|read + goodreads read + kindle read reject empty/wrong verb.
	pocketcasts := New(Wave1Specs()[70], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = pocketcasts.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pocketcasts", Verb: manifest.Play, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("pocketcasts empty draft err = %v", err)
	}
	_, err = pocketcasts.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pocketcasts", Verb: manifest.Send, Body: "open This American Life on Pocket Casts",
	})
	if err == nil {
		t.Fatal("send was accepted on Pocket Casts prepare-and-open adapter")
	}
	_, err = pocketcasts.Resolve(context.Background(), adapter.Intent{
		AdapterID: "pocketcasts", Verb: manifest.Write, Body: "open This American Life on Pocket Casts",
	})
	if err == nil {
		t.Fatal("write was accepted on Pocket Casts prepare-and-open adapter")
	}
	goodreads := New(Wave1Specs()[71], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = goodreads.Resolve(context.Background(), adapter.Intent{
		AdapterID: "goodreads", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("goodreads empty draft err = %v", err)
	}
	_, err = goodreads.Resolve(context.Background(), adapter.Intent{
		AdapterID: "goodreads", Verb: manifest.Write, Body: "open Project Hail Mary on Goodreads",
	})
	if err == nil {
		t.Fatal("write was accepted on Goodreads prepare-and-open adapter")
	}
	_, err = goodreads.Resolve(context.Background(), adapter.Intent{
		AdapterID: "goodreads", Verb: manifest.Send, Body: "open Project Hail Mary on Goodreads",
	})
	if err == nil {
		t.Fatal("send was accepted on Goodreads prepare-and-open adapter")
	}
	kindle := New(Wave1Specs()[72], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = kindle.Resolve(context.Background(), adapter.Intent{
		AdapterID: "kindle", Verb: manifest.Read, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("kindle empty draft err = %v", err)
	}
	_, err = kindle.Resolve(context.Background(), adapter.Intent{
		AdapterID: "kindle", Verb: manifest.Play, Body: "open my Kindle library",
	})
	if err == nil {
		t.Fatal("play was accepted on Kindle prepare-and-open adapter")
	}
	_, err = kindle.Resolve(context.Background(), adapter.Intent{
		AdapterID: "kindle", Verb: manifest.Send, Body: "open my Kindle library",
	})
	if err == nil {
		t.Fatal("send was accepted on Kindle prepare-and-open adapter")
	}
	// Callers: Wave1Specs → adapters/deeplink reject tests (this file).
	// User ask: Wave1Specs 73 → 76 — claude/chatgpt/grok compose reject empty/wrong verb.
	// Pack goal: prepare-and-open only; never claim replied/sent/answered/completed chat.
	claude := New(Wave1Specs()[73], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = claude.Resolve(context.Background(), adapter.Intent{
		AdapterID: "claude", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("claude empty draft err = %v", err)
	}
	_, err = claude.Resolve(context.Background(), adapter.Intent{
		AdapterID: "claude", Verb: manifest.Send, Body: "draft a Claude prompt about weekend plans",
	})
	if err == nil {
		t.Fatal("send was accepted on Claude prepare-and-open adapter")
	}
	chatgpt := New(Wave1Specs()[74], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = chatgpt.Resolve(context.Background(), adapter.Intent{
		AdapterID: "chatgpt", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("chatgpt empty draft err = %v", err)
	}
	_, err = chatgpt.Resolve(context.Background(), adapter.Intent{
		AdapterID: "chatgpt", Verb: manifest.Send, Body: "draft a ChatGPT prompt about weekend plans",
	})
	if err == nil {
		t.Fatal("send was accepted on ChatGPT prepare-and-open adapter")
	}
	grok := New(Wave1Specs()[75], slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err = grok.Resolve(context.Background(), adapter.Intent{
		AdapterID: "grok", Verb: manifest.Compose, Body: "  ",
	})
	if !errors.Is(err, ErrEmptyDraft) {
		t.Fatalf("grok empty draft err = %v", err)
	}
	_, err = grok.Resolve(context.Background(), adapter.Intent{
		AdapterID: "grok", Verb: manifest.Send, Body: "draft a Grok prompt about weekend plans",
	})
	if err == nil {
		t.Fatal("send was accepted on Grok prepare-and-open adapter")
	}
}

func TestDeepLinkRevokeIsNoOp(t *testing.T) {
	a := New(Wave1Specs()[0], nil)
	if err := a.Revoke(context.Background()); err != nil {
		t.Fatalf("revoke: %v", err)
	}
}
