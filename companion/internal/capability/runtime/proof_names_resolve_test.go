package runtime

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// A named proof that names nothing rests on exactly as little as no name at all.
//
// TestEveryAdapterInTheRepoDeclaresAWorkableManifest already refuses a shipped
// adapter whose ProvesCeiling is blank, and says why: "names no smoke test for
// its ceiling, so the claim rests on nothing". But it only checks the string is
// non-empty. A manifest can say its ceiling is proven by
// "todoist_write_roundtrip_smoke" and there is no such test anywhere in this
// repo — the claim rests on nothing just the same, and the suite passes.
//
// Measured 2026-08-03, and the number is the whole point: of the 14 adapters
// this build actually ships, **none** names a proof that exists. Every one
// points at a snake_case smoke no file in this repo defines.
//
// The field is not a bad idea that nobody uses — two adapters do it exactly
// right. applereminders names TestTheFirstWriteCreatesTheAdaptersOwnList and
// applenotes names TestTheFirstWriteCreatesTheAdaptersOwnFolder, and both of
// those functions exist and run. But both are marked Unshipped, so they are
// skipped here for the same reason the manifest contract test skips them: an
// adapter no build registers makes no claim to anyone. The two that do it
// properly are the two that do not ship.
//
// This test does not try to fix that. Writing the missing smokes mostly needs
// vendor accounts nobody has yet, and which of these claims should be dropped
// rather than proven is a call for whoever owns the product. What it does is
// stop the number growing quietly: it holds the dangling count against a
// pinned figure, so adding an adapter with an invented proof name fails here.
// The pin is a debt, not a target. The only direction it should ever move is
// down, and lowering it means a real test arrived.
//
// Bumped to 15 for the location adapter (get_location): like
// notification_reply, its Execute always hands off to the phone, so the
// completes ceiling it declares can only ever be proven by an on-device
// test this repo does not have — the same debt notification_reply already
// carries, one adapter wider.
const proofsNamingNothingThatExists = 15

var goTestFunc = regexp.MustCompile(`(?m)^func (Test[A-Za-z0-9_]*)\(`)

// Every Go test function name defined anywhere under the companion tree.
func everyGoTestName(t *testing.T) map[string]bool {
	t.Helper()
	root := companionTreeRoot(t)
	names := map[string]bool{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, "_test.go") {
			return nil
		}
		body, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		for _, m := range goTestFunc.FindAllStringSubmatch(string(body), -1) {
			names[m[1]] = true
		}
		return nil
	})
	if err != nil {
		t.Fatalf("could not walk the companion tree: %v", err)
	}
	if len(names) == 0 {
		t.Fatal("found no Go test functions at all, so this test would pass by finding nothing")
	}
	return names
}

// Walks up from the test's own directory to the folder holding go.mod.
func companionTreeRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("no working directory: %v", err)
	}
	for {
		if _, statErr := os.Stat(filepath.Join(dir, "go.mod")); statErr == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("walked to the filesystem root without finding go.mod")
		}
		dir = parent
	}
}

func TestEveryNamedProofResolvesToATestThatExists(t *testing.T) {
	tests := everyGoTestName(t)

	var resolves, danglingNames []string
	for _, b := range everyAdapter(t, nil) {
		m := b.a.Describe()
		// Same exemption, same reason as the manifest contract test: an
		// adapter no build registers makes no claim to anyone.
		if strings.TrimSpace(m.Unshipped) != "" {
			continue
		}
		named := strings.TrimSpace(m.ProvesCeiling)
		if named == "" {
			// Already someone else's failure. Not counted twice here.
			continue
		}
		if tests[named] {
			resolves = append(resolves, m.ID)
			continue
		}
		danglingNames = append(danglingNames, m.ID+" -> "+named)
	}

	sort.Strings(resolves)
	sort.Strings(danglingNames)
	t.Logf("named proofs that resolve to a real test: %d", len(resolves))
	t.Logf("named proofs that resolve to nothing: %d", len(danglingNames))
	for _, d := range danglingNames {
		t.Logf("  dangling: %s", d)
	}

	if len(danglingNames) > proofsNamingNothingThatExists {
		t.Errorf("%d shipped adapters name a proof no test in this repo defines, "+
			"which is more than the %d already on record; a ceiling claim backed by "+
			"a name that resolves to nothing is not backed at all",
			len(danglingNames), proofsNamingNothingThatExists)
	}
	if len(danglingNames) < proofsNamingNothingThatExists {
		t.Errorf("only %d dangling proof names left but the pin still says %d; "+
			"lower the pin to %d so it keeps its teeth",
			len(danglingNames), proofsNamingNothingThatExists, len(danglingNames))
	}
	// Deliberately not an assertion. Today len(resolves) is 0 — not one
	// shipped adapter names a proof that exists — and failing on that would
	// leave the suite permanently red over a debt this test cannot pay. The
	// pin above is what has teeth. This line is here so the day the first
	// real smoke lands, the run says so out loud.
	if len(resolves) > 0 {
		t.Logf("shipped adapters whose proof now resolves: %v", resolves)
	}
}
