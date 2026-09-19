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
	"database/sql"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
	appPkg "github.com/openclaw/wacli/internal/app"
	"github.com/openclaw/wacli/internal/lock"
	"github.com/openclaw/wacli/internal/out"
	"github.com/openclaw/wacli/internal/sqliteutil"
	"github.com/openclaw/wacli/internal/store"
	"go.mau.fi/whatsmeow/types"
)

var errNotLinked = errors.New("not linked")

type readRequest struct {
	kind, store, chat string
	limit             int
}
type readRunner func(context.Context, readRequest) (interface{}, error)
type readService struct{ run readRunner }

type chatResult struct {
	JID           string    `json:"jid"`
	Kind          string    `json:"kind"`
	Name          string    `json:"name"`
	LastMessageAt time.Time `json:"lastMessageAt"`
	UnreadCount   int       `json:"unreadCount"`
}
type messageResult struct {
	ChatJID    string    `json:"chatJid"`
	MessageID  string    `json:"messageId"`
	SenderJID  string    `json:"senderJid"`
	SenderName string    `json:"senderName,omitempty"`
	Timestamp  time.Time `json:"timestamp"`
	FromMe     bool      `json:"fromMe"`
	Text       string    `json:"text"`
	Type       string    `json:"type,omitempty"`
}

func newReadService(run readRunner) *readService { return &readService{run: run} }
func (s *readService) chats(storePath string, limit int) string {
	return s.read(readRequest{kind: "chats", store: storePath, limit: limit})
}
func (s *readService) messages(storePath, chat string, limit int) string {
	return s.read(readRequest{kind: "messages", store: storePath, chat: chat, limit: limit})
}
func (s *readService) read(request readRequest) string {
	if !validStore(request.store) || request.limit < 1 || request.limit > 50 {
		return failure("invalid_request")
	}
	if request.kind == "messages" {
		jid, err := types.ParseJID(request.chat)
		if err != nil || jid.IsEmpty() || jid.Server == "" || strings.Count(request.chat, "@") != 1 || len(request.chat) > 256 {
			return failure("invalid_request")
		}
	}
	value, err := s.run(context.Background(), request)
	if errors.Is(err, errNotLinked) {
		return failure("not_linked")
	}
	if err != nil {
		return failure("not_available")
	}
	return success(value)
}

func validStore(path string) bool {
	return filepath.IsAbs(path) && len(path) <= 4096 && !strings.ContainsAny(path, "?#")
}

func runRead(ctx context.Context, request readRequest) (interface{}, error) {
	linked, err := linkedReadOnly(request.store)
	if err != nil {
		return nil, err
	}
	if !linked {
		return nil, errNotLinked
	}
	db, err := store.OpenReadOnly(filepath.Join(request.store, "wacli.db"))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if request.kind == "chats" {
		rows, err := db.ListChats("", request.limit)
		if err != nil {
			return nil, err
		}
		result := make([]chatResult, 0, len(rows))
		for _, row := range rows {
			result = append(result, chatResult{row.JID, row.Kind, row.Name, row.LastMessageTS, row.UnreadCount})
		}
		return map[string]interface{}{"chats": result}, nil
	}
	rows, err := db.ListMessages(store.ListMessagesParams{ChatJID: request.chat, Limit: request.limit})
	if err != nil {
		return nil, err
	}
	result := make([]messageResult, 0, len(rows))
	for _, row := range rows {
		text := row.DisplayText
		if text == "" {
			text = row.Text
		}
		result = append(result, messageResult{row.ChatJID, row.MsgID, row.SenderJID, row.SenderName, row.Timestamp, row.FromMe, text, row.MediaType})
	}
	return map[string]interface{}{"messages": result}, nil
}

func linkedReadOnly(storePath string) (bool, error) {
	path := filepath.Join(storePath, "session.db")
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	db, err := sql.Open("sqlite3", sqliteutil.FileURI(path, "mode=ro&_query_only=1&_busy_timeout=1000"))
	if err != nil {
		return false, err
	}
	defer db.Close()
	var jid string
	err = db.QueryRow("SELECT jid FROM whatsmeow_device LIMIT 1").Scan(&jid)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(jid) != "", nil
}

type syncRunner func(context.Context, string, time.Duration) (int64, error)
type syncOperation struct {
	id, phase string
	messages  int64
	cancel    context.CancelFunc
}
type syncService struct {
	mu         sync.Mutex
	operations map[string]*syncOperation
	run        syncRunner
}
type syncPublic struct {
	OperationID    string `json:"operationId"`
	Phase          string `json:"phase"`
	MessagesStored int64  `json:"messagesStored,omitempty"`
}

func newSyncService(run syncRunner) *syncService {
	return &syncService{operations: map[string]*syncOperation{}, run: run}
}
func (s *syncService) start(storePath string, timeoutSeconds int) string {
	if !validStore(storePath) || timeoutSeconds < 1 || timeoutSeconds > 60 {
		return failure("invalid_request")
	}
	id, err := randomID()
	if err != nil {
		return failure("not_available")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	op := &syncOperation{id: id, phase: "syncing", cancel: cancel}
	s.mu.Lock()
	for _, current := range s.operations {
		if current.phase == "syncing" {
			s.mu.Unlock()
			cancel()
			return failure("sync_in_progress")
		}
	}
	s.operations[id] = op
	s.mu.Unlock()
	go func() {
		messages, err := s.run(ctx, storePath, time.Duration(timeoutSeconds)*time.Second)
		s.mu.Lock()
		defer s.mu.Unlock()
		if op.phase == "cancelled" {
			return
		}
		op.messages = messages
		if errors.Is(err, errNotLinked) {
			op.phase = "not_linked"
		} else if err == nil {
			op.phase = "completed"
		} else if errors.Is(err, context.DeadlineExceeded) {
			op.phase = "timed_out"
		} else {
			op.phase = "failed"
		}
	}()
	return success(syncPublic{id, op.phase, 0})
}
func (s *syncService) status(id string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	op := s.operations[id]
	if op == nil {
		return failure("not_available")
	}
	return success(syncPublic{op.id, op.phase, op.messages})
}
func (s *syncService) cancel(id string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	op := s.operations[id]
	if op == nil {
		return failure("not_available")
	}
	if op.phase == "syncing" {
		op.phase = "cancelled"
		op.cancel()
	}
	return success(syncPublic{op.id, op.phase, op.messages})
}

func runSync(ctx context.Context, storePath string, timeout time.Duration) (int64, error) {
	linked, err := linkedReadOnly(storePath)
	if err != nil {
		return 0, err
	}
	if !linked {
		return 0, errNotLinked
	}
	lk, err := lock.AcquireWithTimeout(ctx, storePath, 0)
	if err != nil {
		return 0, err
	}
	defer lk.Release()
	a, err := appPkg.New(appPkg.Options{StoreDir: storePath, Version: "0.17.1", Events: out.NewEventWriter(io.Discard, false)})
	if err != nil {
		return 0, err
	}
	defer a.Close()
	result, err := a.Sync(ctx, appPkg.SyncOptions{Mode: appPkg.SyncModeOnce, AllowQR: false, RefreshContacts: true, RefreshGroups: true, RefreshChannels: true, IdleExit: minDuration(5*time.Second, timeout)})
	return result.MessagesStored, err
}
func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

var reads = newReadService(runRead)
var syncs = newSyncService(runSync)

//export WacliListChats
func WacliListChats(storePath *C.char, limit C.int) *C.char {
	return C.CString(reads.chats(goString(storePath), int(limit)))
}

//export WacliListMessages
func WacliListMessages(storePath, chat *C.char, limit C.int) *C.char {
	return C.CString(reads.messages(goString(storePath), goString(chat), int(limit)))
}

//export WacliStartSync
func WacliStartSync(storePath *C.char, timeoutSeconds C.int) *C.char {
	return C.CString(syncs.start(goString(storePath), int(timeoutSeconds)))
}

//export WacliSyncStatus
func WacliSyncStatus(operationID *C.char) *C.char {
	return C.CString(syncs.status(goString(operationID)))
}

//export WacliCancelSync
func WacliCancelSync(operationID *C.char) *C.char {
	return C.CString(syncs.cancel(goString(operationID)))
}
