package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapter"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/applenotes"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/applereminders"
	beepermessage "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/beepermessage"
	deeplinkadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/deeplink"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/gcalendar"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/gdrive"
	getlocationadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/getlocation"
	instagramadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/instagram"
	mapsadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/maps"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/msteams"
	notificationreplyadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/notificationreply"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/notion"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/outlook"
	podcastsadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/podcasts"
	slackadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/slack"
	spotifyadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/spotify"
	todoistadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/todoist"
	youtubeadapter "github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/youtube"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/manifest"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/messaging/beeper"
)

// The other half of the contract suite, and the reason it needed one.
//
// contract_test.go holds its rules against whatever the production build
// registered. That is the right set to check — it is what a real install
// gets — but on a machine with no API keys, which is exactly what a CI
// runner is, that set collapses to the credential-free deep-link family and
// Instagram. Two code paths, both hand-off, neither making a single network
// call. The count looks like seventy-odd adapters and is really two.
//
// So the very bug that motivated the suite — Maps reporting a `completes`
// ceiling on a hand-off — would sail through it on CI, because Maps is not
// registered there at all. A suite that cannot catch the bug it was written
// for is a suite that reports comfort.
//
// This file fixes that by building every adapter in the repo directly,
// each with a stand-in service behind it, and holding the shared rules
// against all of them. No credential is needed because no real service is
// contacted: every constructor in every adapter package is a nil-check and
// a struct literal, so building one costs nothing and reaches nothing.
//
// It also adds the rule the plan names that nothing anywhere tested:
// "fails closed when its runtime is down". That rule is meaningless against
// adapters with no runtime, which is all CI had. Here every adapter that
// has a service gets one that is switched off.

// errRuntimeDown is what every stand-in service returns in the fails-closed
// run. It stands for the whole family of ways a backend is unreachable:
// the token expired, the host is down, the network is gone.
var errRuntimeDown = errors.New("contract suite: the service behind this adapter is unreachable")

// ---- stand-in services ----------------------------------------------------
//
// One per adapter package, because the interfaces return package-specific
// types and no single struct can satisfy two of them. Each returns whatever
// `err` holds: an error for the fails-closed run, nil for the runs that need
// a working service. Empty results on the nil path are deliberate — an
// adapter has to cope with a service that is up and simply has nothing.

type serviceState struct{ err error }

func (s serviceState) Clear(context.Context) error { return s.err }

type stubMaps struct{ serviceState }

func (s stubMaps) SearchPlace(context.Context, string) (mapsadapter.Place, error) {
	return mapsadapter.Place{}, s.err
}
func (s stubMaps) ComputeRoute(context.Context, string, string) (mapsadapter.Route, error) {
	return mapsadapter.Route{}, s.err
}

type stubYouTube struct{ serviceState }

func (s stubYouTube) Search(context.Context, string) ([]youtubeadapter.Video, error) {
	return nil, s.err
}

type stubPodcasts struct{ serviceState }

func (s stubPodcasts) Fetch(context.Context, string) ([]podcastsadapter.Episode, error) {
	return nil, s.err
}

type stubSpotify struct{ serviceState }

func (s stubSpotify) Search(context.Context, string) ([]spotifyadapter.Track, error) {
	return nil, s.err
}
func (s stubSpotify) Devices(context.Context) ([]spotifyadapter.Device, error) { return nil, s.err }
func (s stubSpotify) Play(context.Context, string, string) error               { return s.err }

type stubTodoist struct{ serviceState }

func (s stubTodoist) ListTasks(context.Context) ([]todoistadapter.Task, error) { return nil, s.err }
func (s stubTodoist) CreateTask(context.Context, todoistadapter.CreateTask) (todoistadapter.Task, error) {
	return todoistadapter.Task{}, s.err
}

type stubSlack struct{ serviceState }

func (s stubSlack) ListChannels(context.Context) ([]slackadapter.Channel, error) {
	return nil, s.err
}
func (s stubSlack) PostMessage(context.Context, slackadapter.PostMessage) (slackadapter.PostedMessage, error) {
	return slackadapter.PostedMessage{}, s.err
}

type stubGCalendar struct{ serviceState }

func (s stubGCalendar) ListEvents(context.Context, string) ([]gcalendar.Event, error) {
	return nil, s.err
}
func (s stubGCalendar) CreateEvent(context.Context, gcalendar.CreateEvent) (gcalendar.Event, error) {
	return gcalendar.Event{}, s.err
}

type stubGDrive struct{ serviceState }

func (s stubGDrive) ListFiles(context.Context, string) ([]gdrive.File, error) { return nil, s.err }
func (s stubGDrive) CreateFile(context.Context, gdrive.CreateFile) (gdrive.File, error) {
	return gdrive.File{}, s.err
}

type stubOutlook struct{ serviceState }

func (s stubOutlook) ListMessages(context.Context, string) ([]outlook.Message, error) {
	return nil, s.err
}
func (s stubOutlook) CreateDraft(context.Context, outlook.CreateDraft) (outlook.Message, error) {
	return outlook.Message{}, s.err
}
func (s stubOutlook) SendMail(context.Context, outlook.SendMail) error { return s.err }

type stubTeams struct{ serviceState }

func (s stubTeams) ListChats(context.Context) ([]msteams.Chat, error) { return nil, s.err }
func (s stubTeams) SendMessage(context.Context, msteams.SendMessage) (msteams.SentMessage, error) {
	return msteams.SentMessage{}, s.err
}

type stubNotes struct{ serviceState }

func (s stubNotes) Run(context.Context, applenotes.Script) (string, error) { return "", s.err }

type stubReminders struct{ serviceState }

func (s stubReminders) Run(context.Context, applereminders.Script) (string, error) {
	return "", s.err
}

type stubNotion struct{ serviceState }

func (s stubNotion) ListTools(context.Context) ([]string, error) { return nil, s.err }
func (s stubNotion) Call(context.Context, string, map[string]any) (json.RawMessage, error) {
	return nil, s.err
}

type stubBeeper struct{ serviceState }

func (s stubBeeper) SearchChats(context.Context, string) ([]beeper.Chat, error) {
	if s.err != nil {
		return nil, s.err
	}
	return []beeper.Chat{{ID: "contract-chat", Network: "Contract Network", Title: "contract suite probe"}}, nil
}
func (s stubBeeper) Accounts(context.Context) ([]beeper.Account, error) {
	if s.err != nil {
		return nil, s.err
	}
	return []beeper.Account{{ID: "contract-account", Network: "Google Messages", Status: "connected"}}, nil
}
func (s stubBeeper) StartChat(context.Context, string, string) (beeper.Chat, error) {
	if s.err != nil {
		return beeper.Chat{}, s.err
	}
	return beeper.Chat{ID: "contract-chat", Network: "Google Messages", Title: "wife"}, nil
}
func (s stubBeeper) Send(context.Context, string, string) (beeper.Sent, error) {
	if s.err != nil {
		return beeper.Sent{}, s.err
	}
	return beeper.Sent{ChatID: "contract-chat", PendingMessageID: "contract-pending"}, nil
}
func (s stubBeeper) SendReply(ctx context.Context, chatID, text, _ string) (beeper.Sent, error) {
	return s.Send(ctx, chatID, text)
}
func (s stubBeeper) ListChats(context.Context, beeper.ListChatsOptions) (beeper.ChatPage, error) {
	if s.err != nil {
		return beeper.ChatPage{}, s.err
	}
	return beeper.ChatPage{}, nil
}
func (s stubBeeper) GetChat(context.Context, string) (beeper.Chat, error) {
	if s.err != nil {
		return beeper.Chat{}, s.err
	}
	return beeper.Chat{ID: "contract-chat", Network: "Contract Network", Title: "contract suite probe", Capabilities: beeper.ChatCapabilities{Edit: 2, Delete: 2, Reply: 2, Reaction: 2, Archive: true}}, nil
}
func (s stubBeeper) ListMessages(context.Context, string, beeper.MessageListOptions) (beeper.MessagePage, error) {
	if s.err != nil {
		return beeper.MessagePage{}, s.err
	}
	return beeper.MessagePage{Items: []beeper.Message{{ID: "m1", Text: "hi", IsSender: false}}}, nil
}
func (s stubBeeper) SearchMessages(context.Context, beeper.SearchMessagesOptions) (beeper.MessagePage, error) {
	if s.err != nil {
		return beeper.MessagePage{}, s.err
	}
	return beeper.MessagePage{}, nil
}
func (s stubBeeper) EditMessage(context.Context, string, string, string) (beeper.Message, error) {
	if s.err != nil {
		return beeper.Message{}, s.err
	}
	return beeper.Message{ID: "m1"}, nil
}
func (s stubBeeper) DeleteMessage(context.Context, string, string) error   { return s.err }
func (s stubBeeper) React(context.Context, string, string, string) error   { return s.err }
func (s stubBeeper) Unreact(context.Context, string, string, string) error { return s.err }
func (s stubBeeper) MarkRead(context.Context, string, string) (beeper.Chat, error) {
	if s.err != nil {
		return beeper.Chat{}, s.err
	}
	return beeper.Chat{ID: "contract-chat"}, nil
}
func (s stubBeeper) MarkUnread(context.Context, string, string) (beeper.Chat, error) {
	if s.err != nil {
		return beeper.Chat{}, s.err
	}
	return beeper.Chat{ID: "contract-chat"}, nil
}
func (s stubBeeper) Archive(context.Context, string, bool) error { return s.err }
func (s stubBeeper) UpdateChat(context.Context, string, beeper.UpdateChatOptions) (beeper.Chat, error) {
	if s.err != nil {
		return beeper.Chat{}, s.err
	}
	return beeper.Chat{ID: "contract-chat"}, nil
}
func (s stubBeeper) SetReminder(context.Context, string, time.Time, bool) error { return s.err }
func (s stubBeeper) ClearReminder(context.Context, string) error                { return s.err }

// ---- building the whole set ----------------------------------------------

// builtAdapter pairs an adapter with whether a service sits behind it.
// The fails-closed rule only means something for the ones that have a
// service to lose; a deep-link hand-off has nothing that can go down, and
// asking it to fail closed would be asking it to fail at nothing.
type builtAdapter struct {
	a      adapter.Adapter
	backed bool
}

// everyAdapter builds one of each adapter in the repo, with `err` as what
// every stand-in service returns. Pass errRuntimeDown for the fails-closed
// run and nil for the rules that need the service to answer.
//
// This is a hand-written list, which is the one thing contract_test.go
// deliberately avoids — it goes through the live registry so a new adapter
// is covered without anyone remembering this file. That trade is made
// knowingly here: there is no registry that holds adapters nobody can
// construct without credentials, so the choice is a list or no coverage at
// all. TestTheHandWrittenListCoversEveryAdapterPackage below is what keeps
// the list from going quietly stale.
func everyAdapter(t *testing.T, err error) []builtAdapter {
	t.Helper()
	log := quietLogger()

	built := []builtAdapter{
		// One deep-link spec stands for the whole family. All sixty-odd
		// share a single implementation and differ only in the app name
		// and package they point at, so running the rules sixty times
		// exercises the same code sixty times and inflates the count
		// without widening the coverage. contract_test.go already runs
		// every one of them as production registers them.
		{a: deeplinkadapter.New(deeplinkadapter.Wave1Specs()[0], log)},
		{a: instagramadapter.New(log)},
		{a: mapsadapter.NewSavedPlaces(log)},
		// Not backed by any service, because it does not call one: it
		// hands the reply to the phone and the phone does the work. That
		// makes it the one adapter here whose Execute returns an error on
		// the *successful* path, so the rules below have to keep telling
		// "the phone is doing it" apart from "it failed".
		{a: notificationreplyadapter.New(log)},
		// Same shape as notification_reply above: not backed by any
		// service, because it hands the read to the phone rather than
		// calling one itself.
		{a: getlocationadapter.New(log)},
		{a: beepermessage.New(beepermessage.Spec{ID: "beeper-contract", Network: "Contract Network", Auth: manifest.AuthNone, Unshipped: "contract-suite stand-in only"}, stubBeeper{serviceState{err}}, log), backed: true},

		{a: mapsadapter.New(stubMaps{serviceState{err}}, log), backed: true},
		{a: youtubeadapter.New(stubYouTube{serviceState{err}}, log), backed: true},
		{a: podcastsadapter.New(
			podcastsadapter.FeedConfig{URL: "https://feed.invalid/contract-suite.xml"},
			stubPodcasts{serviceState{err}}, log), backed: true},
		{a: spotifyadapter.New(stubSpotify{serviceState{err}}, log), backed: true},
		{a: todoistadapter.New(stubTodoist{serviceState{err}}, log), backed: true},
		{a: slackadapter.New(stubSlack{serviceState{err}}, log), backed: true},
		{a: gcalendar.New(stubGCalendar{serviceState{err}}, log), backed: true},
		{a: gdrive.New(stubGDrive{serviceState{err}}, log), backed: true},
		{a: outlook.New(stubOutlook{serviceState{err}}, log), backed: true},
		{a: msteams.New(stubTeams{serviceState{err}}, log), backed: true},
	}

	notes, buildErr := applenotes.New(stubNotes{serviceState{err}})
	if buildErr != nil {
		t.Fatalf("apple notes adapter would not build: %v", buildErr)
	}
	reminders, buildErr := applereminders.New(stubReminders{serviceState{err}})
	if buildErr != nil {
		t.Fatalf("apple reminders adapter would not build: %v", buildErr)
	}
	page, buildErr := notion.New(stubNotion{serviceState{err}})
	if buildErr != nil {
		t.Fatalf("notion adapter would not build: %v", buildErr)
	}
	built = append(built,
		builtAdapter{a: notes, backed: true},
		builtAdapter{a: reminders, backed: true},
		builtAdapter{a: page, backed: true},
	)

	return built
}

// probe is the one intent shape every rule here resolves with. Body is set
// on purpose: without it most adapters refuse to resolve at all, every loop
// iteration skips, and the whole file passes having checked nothing. That
// is not hypothetical — it is what the first version of contract_test.go
// did, and it reported green.
func probe(id string, verb manifest.Verb) adapter.Intent {
	return adapter.Intent{
		AdapterID: id,
		Verb:      verb,
		Subject:   "contract suite probe",
		Handle:    "contract-suite",
		Body:      "contract suite body",
	}
}

// ---- the rule CI never had ------------------------------------------------

// An adapter whose service is unreachable has exactly two honest answers:
// refuse, or hand off to the app and say so. What it must never do is
// report that it completed something, because nothing was completed —
// the request never left the building.
//
// This is the failure that costs the most trust. A refusal is annoying and
// a hand-off is a bit of work, but "sent" when nothing was sent means the
// user believes a message arrived that never did, and they find out from
// the other person, days later.
func TestEveryAdapterFailsClosedWhenItsServiceIsDown(t *testing.T) {
	ctx := context.Background()
	var reachedExecute, exercised int

	for _, b := range everyAdapter(t, errRuntimeDown) {
		if !b.backed {
			continue
		}
		m := b.a.Describe()
		exercised++
		for _, verb := range m.Verbs {
			plan, err := b.a.Resolve(ctx, probe(m.ID, verb))
			if err != nil {
				// Refusing before it starts is failing closed, correctly.
				continue
			}
			if _, err := b.a.Preview(ctx, plan); err != nil {
				continue
			}
			out, err := b.a.Execute(ctx, plan)
			if err != nil {
				continue
			}
			reachedExecute++

			if out.Reached == manifest.Completes {
				t.Errorf("%s reported it completed %s with its service unreachable; "+
					"nothing was completed and the user is told it was", m.ID, verb)
			}
			if out.Done && out.HandedOffTo == "" {
				t.Errorf("%s reported %s finished with its service unreachable and named no app "+
					"it handed to, so there is nowhere the work could have gone", m.ID, verb)
			}
			if !out.Reached.Valid() {
				t.Errorf("%s reported ceiling %q for %s, which is not a real ceiling; "+
					"Rank scores an unknown value below every real one, so this becomes "+
					"the adapter's permanent record", m.ID, out.Reached, verb)
			}
		}
	}

	if exercised == 0 {
		t.Fatal("no adapter with a service behind it was built, so this test asserted nothing at all")
	}
	t.Logf("adapters with a service: %d, of which reached an outcome with the service down: %d",
		exercised, reachedExecute)
}

// ---- the shared rules, now over every adapter -----------------------------

// Same rule as contract_test.go's, over the whole set rather than the two
// code paths a credential-free build registers. A manifest is the only
// thing the router, the kill list and the ceiling clamp ever read, so a
// broken one is invisible everywhere else.
func TestEveryAdapterInTheRepoDeclaresAWorkableManifest(t *testing.T) {
	seen := map[string]bool{}
	for _, b := range everyAdapter(t, nil) {
		m := b.a.Describe()
		if m.ID == "" {
			t.Error("an adapter has no id")
			continue
		}
		if seen[m.ID] {
			t.Errorf("two adapters answer to the id %q; the registry refuses the second, "+
				"so one of them silently never ships", m.ID)
		}
		seen[m.ID] = true

		if err := m.Validate(); err != nil {
			t.Errorf("%s has an invalid manifest: %v", m.ID, err)
		}
		if len(m.Verbs) == 0 {
			t.Errorf("%s declares no verbs, so nothing can ever route to it", m.ID)
		}
		if !m.Ceiling.Valid() {
			t.Errorf("%s declares ceiling %q, which is not one of the three real ones", m.ID, m.Ceiling)
		}

		// An adapter no build registers makes no claim to any user, so it
		// is not asked to name a proof. Everything above still applies:
		// being unshipped excuses an adapter from proving its ceiling, not
		// from having a coherent manifest. The reason has to be written
		// down in the manifest itself, so the exemption cannot be taken
		// quietly, and TestNothingMarkedUnshippedIsActuallyShipped below is
		// what stops it being taken falsely.
		if strings.TrimSpace(m.Unshipped) != "" {
			continue
		}
		if strings.TrimSpace(m.ProvesCeiling) == "" {
			t.Errorf("%s names no smoke test for its ceiling, so the claim rests on nothing", m.ID)
		}
	}
}

// The teeth on the exemption above. "Not shipped" is the one way an adapter
// gets out of proving its ceiling, so it has to be true — otherwise it is
// just a line anyone can add to make this suite stop complaining, and the
// next unproved capability reaches a real phone with a note in its manifest
// saying it never would.
//
// Checked against what production actually registers, not against a list,
// because the claim being tested is precisely "no build registers this".
func TestNothingMarkedUnshippedIsActuallyShipped(t *testing.T) {
	for _, a := range productionAdapters(t) {
		m := a.Describe()
		if reason := strings.TrimSpace(m.Unshipped); reason != "" {
			t.Errorf("%s is registered by the production build while its manifest says it is not shipped (%q); "+
				"it is reaching real users without a proof behind its ceiling", m.ID, reason)
		}
	}
}

// A verb an adapter accepts but never declared is a capability nobody agreed
// to, that no manifest shows and no kill list can reach. Checked here over
// every adapter, including the seven that need an OAuth sign-in and are
// therefore never registered in any unattended build.
func TestNoAdapterInTheRepoResolvesAVerbItNeverDeclared(t *testing.T) {
	ctx := context.Background()
	var checked int
	for _, b := range everyAdapter(t, nil) {
		m := b.a.Describe()
		verb, ok := undeclaredVerb(m)
		if !ok {
			continue
		}
		checked++
		if _, err := b.a.Resolve(ctx, probe(m.ID, verb)); err == nil {
			t.Errorf("%s resolved %s, a verb it never declared", m.ID, verb)
		}
	}
	if checked == 0 {
		t.Fatal("every adapter declared all nine verbs, which cannot be right; this test asserted nothing")
	}
}

// Revoke is the user taking their access back. It is run here against a
// service that answers, because a revoke against a dead service failing is
// not the interesting case — the interesting case is a revoke that works
// once and then reports failure to anything that retries, which is what a
// user sees as "it says I am still connected".
func TestEveryAdapterInTheRepoRevokesAndStaysRevoked(t *testing.T) {
	ctx := context.Background()
	for _, b := range everyAdapter(t, nil) {
		id := b.a.Describe().ID
		if err := b.a.Revoke(ctx); err != nil {
			t.Errorf("%s failed to revoke: %v", id, err)
			continue
		}
		if err := b.a.Revoke(ctx); err != nil {
			t.Errorf("%s revoked once but failed the second time: %v", id, err)
		}
	}
}

// The hand-written list above is the weak point of this whole file: an
// adapter added in a new package is covered by nothing until someone
// remembers to add it here, and nobody remembers. This counts the adapter
// packages on disk against the list, so adding one without adding it here
// fails rather than quietly shrinking the coverage.
func TestTheHandWrittenListCoversEveryAdapterPackage(t *testing.T) {
	// This test used to compare a hand-written list of names against a
	// hand-written count of them. Both halves were the expectation, so
	// nothing about the actual repository was ever consulted and adding a
	// package could not make it fail — which is what happened: the
	// notification-reply adapter was added and this test stayed green while
	// covering none of it.
	//
	// The old comment said a test that discovers its own expectation cannot
	// fail. That is true, and it is not what reading the directory does
	// here. The directory is the *thing being checked* — which adapters this
	// repository actually contains. The list below is the *expectation* —
	// which of them the rules in this file cover. Comparing those two is the
	// whole point. Comparing the expectation to itself was the bug.
	covered := []string{
		"applenotes", "applereminders", "beepermessage", "deeplink", "gcalendar", "gdrive",
		"getlocation", "instagram", "maps", "msteams", "notion", "outlook",
		"notificationreply", "podcasts", "slack", "spotify", "todoist", "youtube",
	}

	entries, err := os.ReadDir("../adapters")
	if err != nil {
		t.Fatalf("could not read the adapters directory: %v", err)
	}
	var onDisk []string
	for _, e := range entries {
		if e.IsDir() {
			onDisk = append(onDisk, e.Name())
		}
	}

	inList := make(map[string]bool, len(covered))
	for _, n := range covered {
		inList[n] = true
	}
	var uncovered []string
	for _, n := range onDisk {
		if !inList[n] {
			uncovered = append(uncovered, n)
		}
	}
	if len(uncovered) > 0 {
		t.Fatalf("these adapter packages exist but no rule in this file covers them: %s — "+
			"add each to everyAdapter above, then to this list", strings.Join(uncovered, ", "))
	}

	onDiskSet := make(map[string]bool, len(onDisk))
	for _, n := range onDisk {
		onDiskSet[n] = true
	}
	var gone []string
	for _, n := range covered {
		if !onDiskSet[n] {
			gone = append(gone, n)
		}
	}
	if len(gone) > 0 {
		t.Fatalf("this list names adapter packages that no longer exist: %s", strings.Join(gone, ", "))
	}

	adapterPackages := len(onDisk)

	// maps ships two adapters from one package, so the built set is one
	// larger than the package count.
	builtFromThosePackages := adapterPackages + 1
	if got := len(everyAdapter(t, nil)); got != builtFromThosePackages {
		t.Fatalf("the list builds %d adapters, expected %d — a new adapter package was added "+
			"and the contract rules in this file do not cover it yet", got, builtFromThosePackages)
	}
}
