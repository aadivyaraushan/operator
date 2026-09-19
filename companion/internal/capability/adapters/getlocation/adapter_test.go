package getlocation

import (
	"context"
	"errors"
	"testing"

	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapter"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/manifest"
)

func locationIntent(verb manifest.Verb) adapter.Intent {
	return adapter.Intent{Verb: verb}
}

// carryOut runs the adapter the way the flow does — Resolve, then Execute —
// and hands back whatever Execute returned. The device hand-off is an *error*
// return, not an outcome, so a test that only looked at the outcome would see
// an empty struct and conclude nothing happened.
func carryOut(t *testing.T, in adapter.Intent) (adapter.Outcome, error) {
	t.Helper()
	a := New(nil)
	plan, err := a.Resolve(context.Background(), in)
	if err != nil {
		return adapter.Outcome{}, err
	}
	return a.Execute(context.Background(), plan)
}

// deviceWork pulls the hand-off out of an error, failing the test if the error
// was anything else.
func deviceWork(t *testing.T, err error) *adapter.DeviceWorkError {
	t.Helper()
	var work *adapter.DeviceWorkError
	if !errors.As(err, &work) {
		t.Fatalf("the adapter did not hand the location read to the phone; it returned %v", err)
	}
	return work
}

// Regression test for the Handle/Text placeholder deviation: validateBody's
// device_action case rejects a blank handle or text, so if either goes back
// to empty this must fail.
func TestALocationReadIsHandedToThePhoneToCarryOut(t *testing.T) {
	_, err := carryOut(t, locationIntent(manifest.Read))

	work := deviceWork(t, err)
	if work.Kind != "get_location" {
		t.Fatalf("kind = %q, want get_location", work.Kind)
	}
	if work.AdapterID != ID {
		t.Fatalf("adapter id = %q, want %q — the ledger cannot look up a ceiling without it", work.AdapterID, ID)
	}
	if work.Ceiling != manifest.Completes {
		t.Fatalf("ceiling = %q, want completes", work.Ceiling)
	}
	if work.Handle == "" {
		t.Fatal("handle is empty — validateBody's device_action case requires a non-blank handle, so this frame would fail validation and the call would time out")
	}
	if work.Text == "" {
		t.Fatal("text is empty — validateBody's device_action case requires non-blank text, so this frame would fail validation and the call would time out")
	}
}

// Only read belongs to this adapter. Any other verb must be refused before
// it reaches the phone.
func TestItRefusesToStartAConversation(t *testing.T) {
	a := New(nil)
	for _, verb := range []manifest.Verb{manifest.Send, manifest.Write, manifest.Compose} {
		if _, err := a.Resolve(context.Background(), adapter.Intent{Verb: verb}); err == nil {
			t.Fatalf("verb %q was accepted; only read belongs to this adapter", verb)
		}
	}
	if !contains(a.Describe().Verbs, manifest.Read) {
		t.Fatal("the adapter does not declare read, so the resolver would never pick it")
	}
}

// An adapter that declares a gate nobody can clear is refused at every door
// (manifest.CheckGates), so declaring one here would leave the whole route
// built and unreachable.
func TestNothingBlocksThisAdapterFromEverRunning(t *testing.T) {
	m := New(nil).Describe()
	if err := m.CheckGates(); err != nil {
		t.Fatalf("the adapter declares a gate nobody can clear, so it can never run: %v", err)
	}
	if err := m.Validate(); err != nil {
		t.Fatalf("the manifest is invalid, so registration would refuse it: %v", err)
	}
	if m.Platform != manifest.PlatformAndroid {
		t.Fatalf("platform = %q; GPS is Android's, so the resolver must only offer this on Android", m.Platform)
	}
}

func contains(verbs []manifest.Verb, want manifest.Verb) bool {
	for _, v := range verbs {
		if v == want {
			return true
		}
	}
	return false
}
