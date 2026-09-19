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

type response struct {
	Success bool `json:"success"`
	Data    struct {
		OperationID string `json:"operationId"`
		Phase       string `json:"phase"`
		PairCode    string `json:"pairCode,omitempty"`
	} `json:"data"`
	Error *struct {
		Code string `json:"code"`
	} `json:"error"`
}

func waitForPhase(t *testing.T, svc *linkService, operationID, phase string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		response := decodeResponse(t, svc.status(operationID))
		if response.Data.Phase == phase || (phase == phaseFailed && response.Error != nil && response.Error.Code == "link_failed") {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("operation %s did not reach %s", operationID, phase)
}

func decodeResponse(t *testing.T, raw string) response {
	t.Helper()
	var got response
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("invalid response JSON: %v: %s", err, raw)
	}
	return got
}

func TestPairCodeLifecycleAndSuccessfulCompletion(t *testing.T) {
	codeReady := make(chan struct{})
	finish := make(chan struct{})
	runner := func(ctx context.Context, store, phone string, callbacks linkCallbacks) error {
		if store != "/private/store" || phone != "+14155550123" {
			t.Fatalf("unexpected runner input: store=%q phone=%q", store, phone)
		}
		callbacks.pairCode("ABCD-1234")
		close(codeReady)
		<-finish
		callbacks.connected()
		return nil
	}
	svc := newLinkService(runner)
	started := decodeResponse(t, svc.start("/private/store", "+14155550123"))
	if !started.Success || started.Data.Phase != phaseWaiting || started.Data.PairCode != "" {
		t.Fatalf("unexpected start: %+v", started)
	}
	<-codeReady
	status := decodeResponse(t, svc.status(started.Data.OperationID))
	if status.Data.Phase != phaseCodeReady || status.Data.PairCode != "ABCD-1234" {
		t.Fatalf("unexpected code state: %+v", status)
	}
	close(finish)
	waitForPhase(t, svc, started.Data.OperationID, phaseLinked)
	linked := decodeResponse(t, svc.status(started.Data.OperationID))
	if linked.Data.PairCode != "" {
		t.Fatalf("linked response leaked stale code: %+v", linked)
	}
}

func TestCancelClearsCodeAndCannotBeReversedByRunner(t *testing.T) {
	codeReady := make(chan struct{})
	runner := func(ctx context.Context, _, _ string, callbacks linkCallbacks) error {
		callbacks.pairCode("1234-5678")
		close(codeReady)
		<-ctx.Done()
		callbacks.connected()
		return ctx.Err()
	}
	svc := newLinkService(runner)
	started := decodeResponse(t, svc.start("/private/store", "+14155550123"))
	<-codeReady
	cancelled := decodeResponse(t, svc.cancel(started.Data.OperationID))
	if cancelled.Data.Phase != phaseCancelled || cancelled.Data.PairCode != "" {
		t.Fatalf("unexpected cancel response: %+v", cancelled)
	}
	waitForPhase(t, svc, started.Data.OperationID, phaseCancelled)
}

func TestFailuresAreSanitized(t *testing.T) {
	svc := newLinkService(func(context.Context, string, string, linkCallbacks) error {
		return errors.New("secret database path and credentials")
	})
	started := decodeResponse(t, svc.start("/private/store", "+14155550123"))
	waitForPhase(t, svc, started.Data.OperationID, phaseFailed)
	failed := decodeResponse(t, svc.status(started.Data.OperationID))
	if !failed.Success || failed.Data.Phase != phaseFailed || failed.Error != nil {
		t.Fatalf("unexpected sanitized failure: %+v", failed)
	}
	if strings.Contains(svc.status(started.Data.OperationID), "secret") {
		t.Fatal("status leaked the runner error")
	}
	if failed.Data.PairCode != "" {
		t.Fatalf("failed response leaked stale code: %+v", failed)
	}
	invalid := decodeResponse(t, svc.start("/private/store", "not-a-phone"))
	if invalid.Success || invalid.Error == nil || invalid.Error.Code != "invalid_request" {
		t.Fatalf("unexpected invalid request: %+v", invalid)
	}
}

func TestFailureStatusKeepsOnlySafeCategory(t *testing.T) {
	cases := []struct{ message, code string }{
		{"WhatsApp requires passkey verification, which wacli cannot safely complete yet; secret", "verification_required"},
		{"WhatsApp requires passkey confirmation, which wacli cannot safely complete yet; secret", "verification_required"},
		{"QR code timed out; run wacli auth again", "code_expired"},
		{"WhatsApp client outdated; update wacli and try again", "client_outdated"},
		{"private secret token and phone", "pairing_failed"},
	}
	for _, tc := range cases {
		svc := newLinkService(func(context.Context, string, string, linkCallbacks) error { return errors.New(tc.message) })
		started := decodeResponse(t, svc.start("/private/store", "+14155550123"))
		waitForPhase(t, svc, started.Data.OperationID, phaseFailed)
		raw := svc.status(started.Data.OperationID)
		var result struct{ Data struct{ FailureCode string } }
		if err := json.Unmarshal([]byte(raw), &result); err != nil {
			t.Fatal(err)
		}
		if result.Data.FailureCode != tc.code {
			t.Errorf("got category %q, want %q", result.Data.FailureCode, tc.code)
		}
		if strings.Contains(raw, "secret") || strings.Contains(raw, "14155550123") {
			t.Fatal("status leaked private details")
		}
	}
}
