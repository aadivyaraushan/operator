package deeplink

import (
	"sort"
	"strings"
	"testing"
)

// Two standing orders about money, moved out of source comments and into
// checks.
//
// Both rules were already true on 2026-09-10, and both were held in exactly
// the place this repo keeps finding is not good enough: a comment. The
// shopping block in adapter.go says "read only — never claim cart/order/
// checkout", and the Kindle spec says "Not Amazon shopping (C2)". Neither
// sentence stops anyone. A new Spec with AppClass "shopping" and Verbs
// [Order], or an id of "amazon", passed every test in this tree before this
// file existed.
//
// Nothing here is a new policy. It is the existing policy, made load-bearing.

// previewFreeClasses are the app classes whose irreversible act is a payment.
//
// A deep-link adapter is hands_off by construction: Execute does nothing but
// build a draft and name the app it handed to (see Adapter.Execute, which
// returns handoff.DraftOutcome and never touches a network). It therefore
// cannot perform an irreversible act, and it cannot show a preview of one
// either. Declaring a verb that RequiresPreview in one of these classes is a
// claim the adapter has no way to keep.
//
// Deliberately not listed: "food". DoorDash and Grubhub declare Order, and
// that is existing, considered behaviour — an Android order intent really
// does carry a prepared order into the app, and their specs already say
// "never claim checkout completed". The distinction being drawn is not
// "ordering is dangerous" but "these three classes end in a card being
// charged with no further step the user must take". If that stops being the
// distinction, change this list deliberately rather than by adding a Spec.
var previewFreeClasses = map[string]string{
	"shopping": "a shopping hand-off can browse; it cannot put anything in a cart or check out",
	"money":    "money movement is deep-link only forever (see manifest.Verb: pay is not a verb)",
	"finance":  "a finance hand-off can open an account view; it cannot move or file anything",
}

func TestNoShoppingMoneyOrFinanceSpecDeclaresAVerbItCannotPerform(t *testing.T) {
	for _, spec := range Wave1Specs() {
		reason, guarded := previewFreeClasses[spec.AppClass]
		if !guarded {
			continue
		}
		for _, v := range spec.Verbs {
			if v.RequiresPreview() {
				t.Errorf("%s (class %s) declares %q, which requires a preview a hands_off "+
					"adapter can never show: %s",
					spec.ID, spec.AppClass, v, reason)
			}
		}
	}
}

// prohibitedApps may never appear in the hand-off pack, whatever a later
// plan says. Each entry carries the reason so removing one has to be an
// argument rather than a deletion.
var prohibitedApps = map[string]string{
	"amazon":    "consent class C2: a federal court enjoined Perplexity's shopping agent on Amazon in March 2026, and the standing order in this repo is to not point a browser at it",
	"robinhood": "consent class C2: trades and transfers are a prohibited action class",
	"coinbase":  "consent class C2: trades and transfers are a prohibited action class",
	"strava":    "named do-not-build in the Wave 1 remaining-walls decision",
	"tinder":    "consent class C3: dating apps are never shipped",
	"hinge":     "consent class C3: dating apps are never shipped",
	"bumble":    "consent class C3: dating apps are never shipped",
}

func TestProhibitedAppsAreAbsentFromTheHandOffPack(t *testing.T) {
	for _, spec := range Wave1Specs() {
		id := strings.ToLower(strings.TrimSpace(spec.ID))
		if reason, banned := prohibitedApps[id]; banned {
			t.Errorf("%s must never ship as a hand-off connector: %s", spec.ID, reason)
		}

		// An id is the thing the registry keys on, but a Spec whose id dodges
		// the list while its AppName names the same service is the same
		// connector with a different label on it. Kindle is the case that
		// proves this needs care: its AppName is "Kindle", not "Amazon
		// Kindle", precisely because it is the reader app and not the store.
		name := strings.ToLower(strings.TrimSpace(spec.AppName))
		for banned, reason := range prohibitedApps {
			if name == banned {
				t.Errorf("%s is named %q, which is a prohibited service: %s", spec.ID, spec.AppName, reason)
			}
		}
	}
}

// The list above is only worth having if it is reachable. If every id on it
// were misspelled it would ban nothing and the test above would still pass,
// green and useless, forever.
func TestTheProhibitedListIsWellFormed(t *testing.T) {
	if len(prohibitedApps) == 0 {
		t.Fatal("the prohibited list is empty, so the ban test cannot fail for any reason")
	}
	var ids []string
	for id, reason := range prohibitedApps {
		if id != strings.ToLower(strings.TrimSpace(id)) {
			t.Errorf("prohibited id %q is not lowercase and trimmed, so it can never match a Spec id", id)
		}
		if strings.TrimSpace(reason) == "" {
			t.Errorf("prohibited id %q carries no reason; removing it would cost nobody an argument", id)
		}
		ids = append(ids, id)
	}
	sort.Strings(ids)
	t.Logf("prohibited hand-off ids: %v", ids)
}

// Guards the guard. previewFreeClasses is keyed by AppClass strings, and a
// class renamed in Wave1Specs would silently empty it — the rule would still
// be written down, still be tested, and cover nothing.
func TestEveryGuardedClassStillExistsInThePack(t *testing.T) {
	present := map[string]int{}
	for _, spec := range Wave1Specs() {
		present[spec.AppClass]++
	}
	for class := range previewFreeClasses {
		if present[class] == 0 {
			t.Errorf("class %q is guarded against preview-requiring verbs but no Spec uses it; "+
				"either the class was renamed and the guard now covers nothing, or the guard is stale",
				class)
		}
	}
	for class, n := range present {
		if _, guarded := previewFreeClasses[class]; guarded {
			t.Logf("guarded class %s covers %d specs", class, n)
		}
	}
}
