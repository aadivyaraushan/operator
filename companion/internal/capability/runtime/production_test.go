package runtime

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/gcalendar"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/gdrive"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/notion"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/outlook"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/slack"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapters/spotify"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/messaging/beeper"
)

// The gap these tests close: every adapter in this repo was reachable only
// from its own owner-only `serve-<name>-proof` command. Ordinary `serve` never
// built a capability flow at all, so handler.go's nil check refused every
// capability request a real phone could send. Roughly fifty adapters, the
// preview sheet and the whole confirm path were finished code that no user
// could reach.
//
// So this file tests the production build itself, not any one adapter: that it
// exists, that nothing registered is unroutable, and that nothing routable is
// unregistered.

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// The base case, and the most important one: a brand-new install with no keys
// for anything. Hand-off adapters need no credential — they only open an app —
// so the inventory must still come up and still be useful. Returning an error
// here would mean a user with no accounts connected gets nothing at all, when
// what they should get is every prepare-and-open app.
func TestProductionFlowComesUpWithNoCredentialsAtAll(t *testing.T) {
	inv, err := NewProduction(ProductionConfig{Logger: quietLogger()})
	if err != nil {
		t.Fatalf("NewProduction with no credentials failed: %v", err)
	}
	if len(inv.Registered) == 0 {
		t.Fatal("no adapters registered; the phone would have nothing to route to")
	}
	// The deep-link pack is the credential-free half. If it is missing, the
	// build silently dropped the only adapters that always work.
	var sawDeeplink bool
	for _, id := range inv.Registered {
		if id == "uber" || id == "doordash" || id == "venmo" {
			sawDeeplink = true
		}
	}
	if !sawDeeplink {
		t.Errorf("registered %d adapters but none of the credential-free deep-link ones: %v",
			len(inv.Registered), inv.Registered)
	}
}

// The invariant that would have caught the original bug: something built but
// unreachable. An adapter in the registry that no class points at can never be
// chosen by the router, so it is dead weight that still reports itself as
// available.
func TestEveryRegisteredAdapterIsReachableFromSomeClass(t *testing.T) {
	inv, err := NewProduction(ProductionConfig{Logger: quietLogger()})
	if err != nil {
		t.Fatalf("NewProduction failed: %v", err)
	}

	routable := map[string]bool{}
	for _, ids := range inv.Classes {
		for _, id := range ids {
			routable[id] = true
		}
	}
	var unreachable []string
	for _, id := range inv.Registered {
		if !routable[id] {
			unreachable = append(unreachable, id)
		}
	}
	if len(unreachable) > 0 {
		t.Errorf("registered but no class routes to them, so nothing can ever pick them: %v", unreachable)
	}
}

// The mirror failure: a class that names an adapter which was never registered.
// The router would choose it and the lookup would fail deep inside the run,
// after the user had already been shown a preview and confirmed it.
func TestEveryRoutableAdapterWasActuallyRegistered(t *testing.T) {
	inv, err := NewProduction(ProductionConfig{Logger: quietLogger()})
	if err != nil {
		t.Fatalf("NewProduction failed: %v", err)
	}

	registered := map[string]bool{}
	for _, id := range inv.Registered {
		registered[id] = true
	}
	for class, ids := range inv.Classes {
		for _, id := range ids {
			if !registered[id] {
				t.Errorf("class %q routes to %q, which was never registered; "+
					"the user would confirm a preview and then hit a missing adapter", class, id)
			}
		}
	}
}

// A missing credential must leave the adapter out entirely, and say why. The
// failure this prevents: an adapter registered without its key, chosen by the
// router because it looked available, and failing only once the user has
// already confirmed.
func TestAnAdapterWithNoCredentialIsLeftOutAndTheReasonIsRecorded(t *testing.T) {
	inv, err := NewProduction(ProductionConfig{Logger: quietLogger()})
	if err != nil {
		t.Fatalf("NewProduction failed: %v", err)
	}

	registered := map[string]bool{}
	for _, id := range inv.Registered {
		registered[id] = true
	}
	if registered["maps"] {
		t.Error("the Maps adapter was registered with no API key; it would fail after the user confirmed")
	}
	reason, ok := inv.Skipped["maps"]
	if !ok {
		t.Fatal("Maps was skipped but no reason was recorded; nobody can tell why it is missing")
	}
	if strings.TrimSpace(reason) == "" {
		t.Error("the skip reason for Maps is blank")
	}
}

// The other half of the same rule: supply the credential and the adapter must
// appear, and must be routable. Otherwise connecting an account would silently
// change nothing.
func TestSupplyingACredentialAddsThatAdapterAndMakesItRoutable(t *testing.T) {
	inv, err := NewProduction(ProductionConfig{
		Logger:     quietLogger(),
		MapsAPIKey: "test-maps-key",
	})
	if err != nil {
		t.Fatalf("NewProduction failed: %v", err)
	}

	var found bool
	for _, id := range inv.Registered {
		if id == "maps" {
			found = true
		}
	}
	if !found {
		t.Fatalf("a Maps API key was supplied but the adapter is missing: registered=%v skipped=%v",
			inv.Registered, inv.Skipped)
	}
	if _, stillSkipped := inv.Skipped["maps"]; stillSkipped {
		t.Error("Maps was registered and also reported as skipped")
	}

	var routable bool
	for _, ids := range inv.Classes {
		for _, id := range ids {
			if id == "maps" {
				routable = true
			}
		}
	}
	if !routable {
		t.Error("Maps was registered but no class routes to it, so the key changed nothing")
	}
}

// Fact-force: extends existing production_test.go; callers=go test ./.../runtime;
// purpose=MapsBrokerBaseURL path (no duplicate file); no data files;
// user: "Maps Go→Android Places/Routes RPC"
func TestMapsBrokerBaseURLRegistersMapsWithoutLinuxAPIKey(t *testing.T) {
	inv, err := NewProduction(ProductionConfig{
		Logger:            quietLogger(),
		MapsBrokerBaseURL: "http://127.0.0.1:9451",
	})
	if err != nil {
		t.Fatalf("NewProduction failed: %v", err)
	}
	var found bool
	for _, id := range inv.Registered {
		if id == "maps" {
			found = true
		}
	}
	if !found {
		t.Fatalf("Android maps broker URL supplied but maps missing: registered=%v skipped=%v",
			inv.Registered, inv.Skipped)
	}
	if _, stillSkipped := inv.Skipped["maps"]; stillSkipped {
		t.Error("Maps was registered and also skipped")
	}
}

type fakeOAuthAPIs struct{}

type fakeNotionSession struct{}

func (*fakeNotionSession) ListTools(context.Context) ([]string, error) {
	return []string{notion.ToolSearch, notion.ToolFetch, notion.ToolCreatePages, notion.ToolUpdatePage}, nil
}
func (*fakeNotionSession) Call(context.Context, string, map[string]any) (json.RawMessage, error) {
	return nil, nil
}

func (*fakeOAuthAPIs) ListEvents(context.Context, string) ([]gcalendar.Event, error) { return nil, nil }
func (*fakeOAuthAPIs) CreateEvent(context.Context, gcalendar.CreateEvent) (gcalendar.Event, error) {
	return gcalendar.Event{}, nil
}
func (*fakeOAuthAPIs) ListFiles(context.Context, string) ([]gdrive.File, error) { return nil, nil }
func (*fakeOAuthAPIs) CreateFile(context.Context, gdrive.CreateFile) (gdrive.File, error) {
	return gdrive.File{}, nil
}
func (*fakeOAuthAPIs) ListChannels(context.Context) ([]slack.Channel, error) { return nil, nil }
func (*fakeOAuthAPIs) PostMessage(context.Context, slack.PostMessage) (slack.PostedMessage, error) {
	return slack.PostedMessage{}, nil
}
func (*fakeOAuthAPIs) ListMessages(context.Context, string) ([]outlook.Message, error) {
	return nil, nil
}
func (*fakeOAuthAPIs) CreateDraft(context.Context, outlook.CreateDraft) (outlook.Message, error) {
	return outlook.Message{}, nil
}
func (*fakeOAuthAPIs) SendMail(context.Context, outlook.SendMail) error        { return nil }
func (*fakeOAuthAPIs) Search(context.Context, string) ([]spotify.Track, error) { return nil, nil }
func (*fakeOAuthAPIs) Devices(context.Context) ([]spotify.Device, error)       { return nil, nil }
func (*fakeOAuthAPIs) Play(context.Context, string, string) error              { return nil }
func (*fakeOAuthAPIs) Clear(context.Context) error                             { return nil }

func TestPersistedOAuthAPIsReplaceHandoffsAndBecomeRoutable(t *testing.T) {
	apis := &fakeOAuthAPIs{}
	notionAdapter, err := notion.New(&fakeNotionSession{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := notionAdapter.Connect(t.Context()); err != nil {
		t.Fatal(err)
	}
	inv, err := NewProduction(ProductionConfig{
		Logger:            quietLogger(),
		GoogleCalendarAPI: apis, GoogleDriveAPI: apis, SlackAPI: apis,
		OutlookAPI: apis, SpotifyAPI: apis, NotionAdapter: notionAdapter,
	})
	if err != nil {
		t.Fatalf("NewProduction: %v", err)
	}
	wantClasses := map[string]string{
		gcalendar.ID: "calendar", gdrive.ID: "drive", slack.ID: "slack",
		outlook.ID: "email", spotify.ID: "media", notion.ID: "notes",
	}
	for id, class := range wantClasses {
		found := false
		for _, candidate := range inv.Classes[class] {
			if candidate == id {
				found = true
			}
		}
		if !found {
			t.Errorf("OAuth adapter %q not routable from class %q: classes=%v", id, class, inv.Classes)
		}
		if _, skipped := inv.Skipped[id]; skipped {
			t.Errorf("OAuth adapter %q is registered and still reported skipped", id)
		}
	}
}

type fakeProductionBeeper struct{}

func (*fakeProductionBeeper) SearchChats(context.Context, string) ([]beeper.Chat, error) {
	return []beeper.Chat{{ID: "chat-1", Network: "Discord", Title: "Aadivya"}}, nil
}
func (*fakeProductionBeeper) Accounts(context.Context) ([]beeper.Account, error) {
	return []beeper.Account{{ID: "google-account-live", Network: "Google Messages", Status: "connected"}}, nil
}
func (*fakeProductionBeeper) StartChat(context.Context, string, string) (beeper.Chat, error) {
	return beeper.Chat{ID: "chat-1", Network: "Google Messages", Title: "wife"}, nil
}
func (*fakeProductionBeeper) Send(context.Context, string, string) (beeper.Sent, error) {
	return beeper.Sent{ChatID: "chat-1", PendingMessageID: "pending-1"}, nil
}
func (f *fakeProductionBeeper) SendReply(ctx context.Context, chatID, text, _ string) (beeper.Sent, error) {
	return f.Send(ctx, chatID, text)
}
func (*fakeProductionBeeper) ListChats(context.Context, beeper.ListChatsOptions) (beeper.ChatPage, error) {
	return beeper.ChatPage{}, nil
}
func (*fakeProductionBeeper) GetChat(context.Context, string) (beeper.Chat, error) {
	return beeper.Chat{ID: "chat-1", Network: "Discord", Title: "Aadivya"}, nil
}
func (*fakeProductionBeeper) ListMessages(context.Context, string, beeper.MessageListOptions) (beeper.MessagePage, error) {
	return beeper.MessagePage{}, nil
}
func (*fakeProductionBeeper) SearchMessages(context.Context, beeper.SearchMessagesOptions) (beeper.MessagePage, error) {
	return beeper.MessagePage{}, nil
}
func (*fakeProductionBeeper) EditMessage(context.Context, string, string, string) (beeper.Message, error) {
	return beeper.Message{}, nil
}
func (*fakeProductionBeeper) DeleteMessage(context.Context, string, string) error { return nil }
func (*fakeProductionBeeper) React(context.Context, string, string, string) error { return nil }
func (*fakeProductionBeeper) Unreact(context.Context, string, string, string) error {
	return nil
}
func (*fakeProductionBeeper) MarkRead(context.Context, string, string) (beeper.Chat, error) {
	return beeper.Chat{ID: "chat-1"}, nil
}
func (*fakeProductionBeeper) MarkUnread(context.Context, string, string) (beeper.Chat, error) {
	return beeper.Chat{ID: "chat-1"}, nil
}
func (*fakeProductionBeeper) Archive(context.Context, string, bool) error { return nil }
func (*fakeProductionBeeper) UpdateChat(context.Context, string, beeper.UpdateChatOptions) (beeper.Chat, error) {
	return beeper.Chat{ID: "chat-1"}, nil
}
func (*fakeProductionBeeper) SetReminder(context.Context, string, time.Time, bool) error { return nil }
func (*fakeProductionBeeper) ClearReminder(context.Context, string) error                { return nil }

func TestBeeperConnectionReplacesTheThreeMessagingHandoffsWithConfirmedSendAdapters(t *testing.T) {
	inv, err := NewProduction(ProductionConfig{
		Logger: quietLogger(), BeeperAPI: &fakeProductionBeeper{},
	})
	if err != nil {
		t.Fatalf("NewProduction: %v", err)
	}

	want := map[string]bool{"instagram": false, "discord": false, "messages": false}
	for _, id := range inv.Classes["beeper_messaging"] {
		if _, ok := want[id]; ok {
			want[id] = true
		}
	}
	for id, found := range want {
		if !found {
			t.Errorf("Beeper send adapter %q is not routable: classes=%v", id, inv.Classes)
		}
	}
	if inv.Classes["messaging"] == nil {
		t.Fatal("the ordinary prepare-and-open messaging class disappeared")
	}
}

func TestPersistentlyDisconnectedCredentialedAdaptersStayOutAfterRebuild(t *testing.T) {
	revoked := []string{}
	inv, err := NewProduction(ProductionConfig{
		Logger: quietLogger(), YouTubeAPIKey: "test-youtube-key", BeeperAPI: &fakeProductionBeeper{},
		Disconnected: map[string]bool{"youtube": true, "discord": true},
		PersistDisconnect: func(_ context.Context, id string) error {
			revoked = append(revoked, id)
			return nil
		},
	})
	if err != nil {
		t.Fatalf("NewProduction: %v", err)
	}
	registered := map[string]bool{}
	for _, id := range inv.Registered {
		registered[id] = true
	}
	if registered["youtube"] || registered["discord"] {
		t.Fatalf("disconnected adapters were rebuilt: registered=%v", inv.Registered)
	}
	if !registered["instagram"] || !registered["messages"] {
		t.Fatalf("one Beeper network disconnect removed its siblings: registered=%v", inv.Registered)
	}
}
