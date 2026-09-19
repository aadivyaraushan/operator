//go:build wacli

// These files are not part of this module's build. build.sh copies them into
// a pinned wacli source tree, where their github.com/openclaw/wacli/internal
// imports resolve; here they cannot compile at all, and without this tag they
// break `go test ./...` — the command the README documents — for the whole
// repository. The tag is what build.sh passes once they are in the right tree.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func operationIDFromJSON(t *testing.T, raw string) string {
	t.Helper()
	var value struct {
		Data struct {
			OperationID string `json:"operationId"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(raw), &value); err != nil || value.Data.OperationID == "" {
		t.Fatalf("invalid operation response: %s", raw)
	}
	return value.Data.OperationID
}

func TestReadValidationIsBoundedBeforeRunner(t *testing.T) {
	calls := 0
	svc := newReadService(func(context.Context, readRequest) (interface{}, error) { calls++; return nil, nil })
	for _, raw := range []string{
		svc.chats("/store", 0), svc.chats("/store", 51),
		svc.messages("/store", "not-a-jid", 10), svc.messages("/store", "x@s.whatsapp.net", 51),
	} {
		if !strings.Contains(raw, `"code":"invalid_request"`) {
			t.Fatalf("unexpected validation response: %s", raw)
		}
	}
	if calls != 0 {
		t.Fatalf("invalid requests reached runner %d times", calls)
	}
}

func TestReadErrorsAreSanitized(t *testing.T) {
	svc := newReadService(func(context.Context, readRequest) (interface{}, error) {
		return nil, errors.New("secret session path")
	})
	raw := svc.chats("/store", 10)
	if !strings.Contains(raw, `"code":"not_available"`) || strings.Contains(raw, "secret") {
		t.Fatalf("unsafe error: %s", raw)
	}
}

func TestMessagePayloadCannotExposePrivateStoreOrPairingFields(t *testing.T) {
	raw, err := json.Marshal(messageResult{ChatJID: "1@s.whatsapp.net", MessageID: "m1", Text: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"DirectPath", "directPath", "LocalPath", "localPath", "MediaKey", "mediaKey", "pairCode", "session"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("payload exposed %s: %s", forbidden, raw)
		}
	}
}

func TestSyncLifecycleTimeoutAndCancel(t *testing.T) {
	started := make(chan struct{})
	svc := newSyncService(func(ctx context.Context, _ string, _ time.Duration) (int64, error) {
		close(started)
		<-ctx.Done()
		return 0, ctx.Err()
	})
	start := svc.start("/store", 5)
	id := operationIDFromJSON(t, start)
	<-started
	cancelled := svc.cancel(id)
	if !strings.Contains(cancelled, `"phase":"cancelled"`) {
		t.Fatalf("unexpected cancel: %s", cancelled)
	}
	time.Sleep(time.Millisecond)
	if got := svc.status(id); !strings.Contains(got, `"phase":"cancelled"`) {
		t.Fatalf("late completion changed cancel: %s", got)
	}
	if got := svc.start("/store", 0); !strings.Contains(got, `"code":"invalid_request"`) {
		t.Fatalf("accepted zero timeout: %s", got)
	}
}
