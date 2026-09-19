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
	"testing"

	"go.mau.fi/whatsmeow/types"
)

func decodeJSON(t *testing.T, raw string, value interface{}) {
	t.Helper()
	if err := json.Unmarshal([]byte(raw), value); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
}

func assertFailureCode(t *testing.T, raw, code string) {
	t.Helper()
	var envelope struct {
		Success bool         `json:"success"`
		Error   *bridgeError `json:"error"`
	}
	decodeJSON(t, raw, &envelope)
	if envelope.Success || envelope.Error == nil || envelope.Error.Code != code {
		t.Fatalf("expected %s: %s", code, raw)
	}
}

func TestSendRejectsInvalidInputWithoutCallingRunner(t *testing.T) {
	calls := 0
	service := newSendService(func(context.Context, sendRequest) (types.MessageID, bool, error) {
		calls++
		return "", false, nil
	})
	for _, test := range []struct {
		store, recipient, body string
		timeout                int
	}{
		{"relative", "12175550100@s.whatsapp.net", "hello", 10},
		{"/tmp/store", "not-a-jid", "hello", 10},
		{"/tmp/store", "12175550100@s.whatsapp.net", "", 10},
		{"/tmp/store", "12175550100@s.whatsapp.net", "hello", 0},
		{"/tmp/store", "12175550100@s.whatsapp.net", "hello", 30_001},
	} {
		assertFailureCode(t, service.send(test.store, test.recipient, test.body, test.timeout), "invalid_request")
	}
	if calls != 0 {
		t.Fatalf("runner called %d times", calls)
	}
}

func TestSendReturnsSentOnlyForServerAcknowledgement(t *testing.T) {
	calls := 0
	service := newSendService(func(_ context.Context, request sendRequest) (types.MessageID, bool, error) {
		calls++
		if request.recipient.String() != "12175550100@s.whatsapp.net" || request.body != " exact body " {
			t.Fatalf("request changed: %#v", request)
		}
		return types.MessageID("server-message-id"), true, nil
	})
	var envelope struct {
		Success bool                                `json:"success"`
		Data    struct{ Outcome, MessageID string } `json:"data"`
	}
	decodeJSON(t, service.send("/tmp/store", "12175550100@s.whatsapp.net", " exact body ", 10_000), &envelope)
	if !envelope.Success || envelope.Data.Outcome != "sent" || envelope.Data.MessageID != "server-message-id" || calls != 1 {
		t.Fatalf("unexpected result: %#v calls=%d", envelope, calls)
	}
}

func TestSendAttemptErrorIsUnknownOutcomeAndNeverRetried(t *testing.T) {
	calls := 0
	service := newSendService(func(context.Context, sendRequest) (types.MessageID, bool, error) {
		calls++
		return "", true, errors.New("connection ended after transmit")
	})
	var envelope struct {
		Success bool `json:"success"`
		Data    struct {
			Outcome string `json:"outcome"`
		} `json:"data"`
		Error *bridgeError `json:"error"`
	}
	decodeJSON(t, service.send("/tmp/store", "12175550100@s.whatsapp.net", "hello", 10_000), &envelope)
	if !envelope.Success || envelope.Data.Outcome != "unknown" || envelope.Error != nil || calls != 1 {
		t.Fatalf("must report one uncertain attempt: %#v calls=%d", envelope, calls)
	}
}

func TestSendPreflightErrorsAreHonest(t *testing.T) {
	for _, test := range []struct {
		err  error
		code string
	}{{errNotLinked, "not_linked"}, {errors.New("store busy"), "not_available"}} {
		service := newSendService(func(context.Context, sendRequest) (types.MessageID, bool, error) { return "", false, test.err })
		assertFailureCode(t, service.send("/tmp/store", "12345@g.us", "hello", 10_000), test.code)
	}
}
