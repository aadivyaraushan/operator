//go:build wacli

// These files are not part of this module's build. build.sh copies them into
// a pinned wacli source tree, where their github.com/openclaw/wacli/internal
// imports resolve; here they cannot compile at all, and without this tag they
// break `go test ./...` — the command the README documents — for the whole
// repository. The tag is what build.sh passes once they are in the right tree.

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"errors"
	appPkg "github.com/openclaw/wacli/internal/app"
	"github.com/openclaw/wacli/internal/lock"
	"github.com/openclaw/wacli/internal/out"
	"go.mau.fi/whatsmeow/types"
	"io"
	"strings"
	"time"
)

type sendRequest struct {
	store, body string
	recipient   types.JID
	timeout     time.Duration
}
type sendRunner func(context.Context, sendRequest) (types.MessageID, bool, error)
type sendService struct{ run sendRunner }
type sendResult struct {
	Outcome   string `json:"outcome"`
	MessageID string `json:"messageId,omitempty"`
}

func newSendService(run sendRunner) *sendService { return &sendService{run: run} }
func (s *sendService) send(storePath, recipient, body string, timeoutMilliseconds int) string {
	jid, err := types.ParseJID(recipient)
	validJID := err == nil && !jid.IsEmpty() && jid.String() == recipient && jid.Device == 0 && (jid.Server == types.DefaultUserServer || jid.Server == types.GroupServer)
	if !validStore(storePath) || !validJID || len(body) == 0 || len([]byte(body)) > 16*1024 || timeoutMilliseconds < 1 || timeoutMilliseconds > 30_000 {
		return failure("invalid_request")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMilliseconds)*time.Millisecond)
	defer cancel()
	messageID, attempted, err := s.run(ctx, sendRequest{store: storePath, recipient: jid, body: body, timeout: time.Duration(timeoutMilliseconds) * time.Millisecond})
	if attempted && (err != nil || messageID == "") {
		return success(sendResult{Outcome: "unknown"})
	}
	if errors.Is(err, errNotLinked) {
		return failure("not_linked")
	}
	if err != nil || messageID == "" {
		return failure("not_available")
	}
	return success(sendResult{Outcome: "sent", MessageID: string(messageID)})
}
func runSend(ctx context.Context, request sendRequest) (types.MessageID, bool, error) {
	linked, err := linkedReadOnly(request.store)
	if err != nil {
		return "", false, err
	}
	if !linked {
		return "", false, errNotLinked
	}
	lk, err := lock.AcquireWithTimeout(ctx, request.store, 0)
	if err != nil {
		return "", false, err
	}
	defer lk.Release()
	a, err := appPkg.New(appPkg.Options{StoreDir: request.store, Version: "0.17.1", Events: out.NewEventWriter(io.Discard, false), AllowUnauthed: true})
	if err != nil {
		return "", false, err
	}
	defer a.Close()
	if err := a.EnsureAuthed(); err != nil {
		return "", false, errNotLinked
	}
	if err := a.Connect(ctx, false, nil); err != nil {
		return "", false, err
	}
	if err := ctx.Err(); err != nil {
		return "", false, err
	}
	messageID, err := a.WA().SendText(ctx, request.recipient, request.body)
	return messageID, true, err
}

var textSendService = newSendService(runSend)

//export WacliSendText
func WacliSendText(store, recipient, body *C.char, timeoutMilliseconds C.int) *C.char {
	return C.CString(textSendService.send(goString(store), strings.TrimSpace(goString(recipient)), goString(body), int(timeoutMilliseconds)))
}
