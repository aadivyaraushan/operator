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
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"
	"unsafe"

	appPkg "github.com/openclaw/wacli/internal/app"
	"github.com/openclaw/wacli/internal/lock"
	"github.com/openclaw/wacli/internal/out"
	"github.com/openclaw/wacli/internal/wa"
)

const (
	phaseWaiting   = "waiting_for_code"
	phaseCodeReady = "code_ready"
	phaseFinishing = "finishing"
	phaseLinked    = "linked"
	phaseFailed    = "failed"
	phaseCancelled = "cancelled"
)

var phonePattern = regexp.MustCompile(`^\+[1-9][0-9]{7,14}$`)

type linkCallbacks struct {
	pairCode  func(string)
	connected func()
}

type linkRunner func(context.Context, string, string, linkCallbacks) error

type operation struct {
	id, phase, pairCode string
	failureCode         string
	cancel              context.CancelFunc
}

type linkService struct {
	mu         sync.Mutex
	operations map[string]*operation
	run        linkRunner
}

type resultEnvelope struct {
	Success bool         `json:"success"`
	Data    interface{}  `json:"data,omitempty"`
	Error   *bridgeError `json:"error,omitempty"`
}

type bridgeError struct {
	Code string `json:"code"`
}

type publicOperation struct {
	OperationID string `json:"operationId"`
	Phase       string `json:"phase"`
	PairCode    string `json:"pairCode,omitempty"`
	FailureCode string `json:"failureCode,omitempty"`
}

func newLinkService(run linkRunner) *linkService {
	return &linkService{operations: make(map[string]*operation), run: run}
}

func (s *linkService) start(store, phone string) string {
	if store == "" || !phonePattern.MatchString(phone) {
		return failure("invalid_request")
	}
	id, err := randomID()
	if err != nil {
		return failure("link_failed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	op := &operation{id: id, phase: phaseWaiting, cancel: cancel}
	s.mu.Lock()
	for _, current := range s.operations {
		if active(current.phase) {
			s.mu.Unlock()
			cancel()
			return failure("link_in_progress")
		}
	}
	s.operations[id] = op
	s.mu.Unlock()
	go s.execute(ctx, op, store, phone)
	return success(s.snapshot(op, false))
}

func (s *linkService) execute(ctx context.Context, op *operation, store, phone string) {
	err := s.run(ctx, store, phone, linkCallbacks{
		pairCode:  func(code string) { s.transition(op, phaseCodeReady, code) },
		connected: func() { s.transition(op, phaseFinishing, "") },
	})
	s.mu.Lock()
	defer s.mu.Unlock()
	if op.phase == phaseCancelled {
		return
	}
	op.pairCode = ""
	if err == nil {
		op.phase = phaseLinked
	} else {
		op.phase = phaseFailed
		op.failureCode = safeLinkFailure(err)
	}
}

// Only fixed categories cross the bridge; raw errors may contain credentials.
func safeLinkFailure(err error) string {
	message := err.Error()
	switch {
	case strings.HasPrefix(message, "WhatsApp requires passkey verification"),
		strings.HasPrefix(message, "WhatsApp requires passkey confirmation"):
		return "verification_required"
	case strings.HasPrefix(message, "QR code timed out"):
		return "code_expired"
	case strings.HasPrefix(message, "WhatsApp client outdated"):
		return "client_outdated"
	default:
		return "pairing_failed"
	}
}

func (s *linkService) transition(op *operation, phase, code string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !active(op.phase) {
		return
	}
	op.phase, op.pairCode = phase, code
}

func (s *linkService) status(id string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	op := s.operations[id]
	if op == nil {
		return failure("not_available")
	}
	return success(s.snapshotLocked(op, true))
}

func (s *linkService) cancel(id string) string {
	s.mu.Lock()
	op := s.operations[id]
	if op == nil {
		s.mu.Unlock()
		return failure("not_available")
	}
	if active(op.phase) {
		op.phase, op.pairCode = phaseCancelled, ""
		op.cancel()
	}
	result := s.snapshotLocked(op, true)
	s.mu.Unlock()
	return success(result)
}

func (s *linkService) snapshot(op *operation, includeCode bool) publicOperation {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked(op, includeCode)
}

func (s *linkService) snapshotLocked(op *operation, includeCode bool) publicOperation {
	result := publicOperation{OperationID: op.id, Phase: op.phase}
	if op.phase == phaseFailed {
		result.FailureCode = op.failureCode
	}
	if includeCode && op.phase == phaseCodeReady {
		result.PairCode = op.pairCode
	}
	return result
}

func active(phase string) bool {
	return phase == phaseWaiting || phase == phaseCodeReady || phase == phaseFinishing
}

func randomID() (string, error) {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes[:]), nil
}

func success(data interface{}) string {
	encoded, _ := json.Marshal(resultEnvelope{Success: true, Data: data})
	return string(encoded)
}

func failure(code string) string {
	encoded, _ := json.Marshal(resultEnvelope{Success: false, Error: &bridgeError{Code: code}})
	return string(encoded)
}

func runWacli(ctx context.Context, store, phone string, callbacks linkCallbacks) error {
	phoneJID, err := wa.ParseUserOrJID(phone)
	if err != nil {
		return err
	}
	lk, err := lock.AcquireWithTimeout(ctx, store, 0)
	if err != nil {
		return err
	}
	defer lk.Release()
	a, err := appPkg.New(appPkg.Options{
		StoreDir: store, Version: "0.17.1", Events: out.NewEventWriter(io.Discard, false), AllowUnauthed: true,
	})
	if err != nil {
		return err
	}
	defer a.Close()
	_, err = a.Sync(ctx, appPkg.SyncOptions{
		Mode: appPkg.SyncModeBootstrap, AllowQR: true, PairPhoneNumber: phoneJID.User,
		OnPairCode: callbacks.pairCode, AfterConnect: func(context.Context) error { callbacks.connected(); return nil },
		RefreshContacts: true, RefreshGroups: true, RefreshChannels: true,
		IdleExit: 30 * time.Second, WarnNoLimits: true,
	})
	if err != nil {
		return err
	}
	if a.WA() == nil || !a.WA().IsAuthed() {
		return errors.New("authentication did not complete")
	}
	return nil
}

var service = newLinkService(runWacli)

//export WacliStartLink
func WacliStartLink(store, phone *C.char) *C.char {
	return C.CString(service.start(goString(store), goString(phone)))
}

//export WacliLinkStatus
func WacliLinkStatus(operationID *C.char) *C.char {
	return C.CString(service.status(goString(operationID)))
}

//export WacliCancelLink
func WacliCancelLink(operationID *C.char) *C.char {
	return C.CString(service.cancel(goString(operationID)))
}

func goString(value *C.char) string {
	if value == nil {
		return ""
	}
	return C.GoString(value)
}

//export WacliFreeString
func WacliFreeString(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func main() {}
