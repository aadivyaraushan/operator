package agentbridge

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync"

	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapter"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/devicework"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/execution"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/manifest"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/registry"
	"github.com/codex-launcher/codex-launcher/companion/internal/phoneruntime/agentbridge/gates"
)

// adapterLister is the one thing the bridge needs from a registry: the ids
// it should describe in the tool list. Both *registry.Registry and
// capability/runtime's Inventory satisfy it, so production wiring can hand
// the bridge either the raw registry (tests) or the read-only Inventory
// view (production.go) without this package importing more than it uses.
type adapterLister interface {
	AdapterIDs() []string
}

// GateDeps is what the bridge needs to run every non-read call through the
// hard-gate policy before it executes. Gating is not optional: there is no
// nil-Policy bypass path, so a Bridge cannot be built without one.
type GateDeps struct {
	Policy   *gates.Policy
	Store    gates.Store
	Notifier ApprovalNotifier
	// AllowListed reports whether recipient is on the owner's rules-file
	// allow list for autonomous sends. Nil means the allow list is empty —
	// nobody is allow-listed.
	AllowListed func(recipient string) bool
	// Disconnector runs an approved disconnect — the agent-side revoke that
	// undoes an adapter's credentials and consent grant. Satisfied by
	// capability/disconnect's Service.
	Disconnector Disconnector
	// DeviceWorker carries an Ask to the phone and waits for its answer,
	// for the adapters that cannot finish where they started (the reply
	// box or player they need lives on the phone). Nil means no phone is
	// wired in at all — every DeviceWorkError then fails the call rather
	// than hanging it. Satisfied by mobilesession.Handler.
	DeviceWorker DeviceWorker
}

// Disconnector is what the bridge needs to run the disconnect verb: undo an
// adapter's credentials and consent grant, and report whether that has
// already happened for a given adapter id.
type Disconnector interface {
	Disconnect(ctx context.Context, adapterID string) error
	Disconnected(adapterID string) bool
}

// DeviceWorker hands an Ask to the connected phone and blocks until it
// answers, ctx ends, or the phone leaves. Satisfied by
// mobilesession.Handler.RunOnDevice.
type DeviceWorker interface {
	RunOnDevice(ctx context.Context, ask devicework.Ask) (devicework.Result, error)
}

// ApprovalNotifier tells the launcher a call stopped for the owner's OK. A
// nil Notifier is a no-op — tests that don't care about the launcher side
// of a gate can leave it unset.
type ApprovalNotifier interface {
	GateRaised(gate gates.Gate, preview PreviewSummary)
}

// pendingCall is one gated call's plan and preview, kept exactly long
// enough for ApproveGate or DenyGate to resolve it.
type pendingCall struct {
	plan      adapter.Plan
	preview   execution.Preview
	adapterID string
	recipient string
	verb      string
}

// Bridge serves the two agent-tool endpoints for one registry and runner.
// Every request must carry the bearer token; the caller (phoneruntime)
// additionally restricts the routes to loopback.
type Bridge struct {
	ids    adapterLister
	runner *execution.Runner
	token  string
	logger *slog.Logger
	gate   GateDeps

	pendingMu sync.Mutex
	pending   map[string]pendingCall
}

// New returns a Bridge. token must be non-empty; a Bridge with an empty
// token refuses every request rather than serving unauthenticated. gate is
// required — every non-read call is judged against gate.Policy before it
// runs.
func New(ids adapterLister, runner *execution.Runner, token string, logger *slog.Logger, gate GateDeps) *Bridge {
	if logger == nil {
		logger = slog.Default()
	}
	return &Bridge{ids: ids, runner: runner, token: token, logger: logger, gate: gate, pending: make(map[string]pendingCall)}
}

// Handler serves GET /v1/agent-tools/list and POST /v1/agent-tools/call.
func (b *Bridge) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !b.authorized(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/v1/agent-tools/list":
			if r.Method != http.MethodGet {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			b.handleList(w, r)
		case "/v1/agent-tools/call":
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			b.handleCall(w, r)
		default:
			http.NotFound(w, r)
		}
	})
}

// authorized checks the bearer token in constant time. An empty configured
// token is a misconfiguration, not open access, so it refuses everything —
// including a request presenting an empty bearer of its own.
func (b *Bridge) authorized(r *http.Request) bool {
	if b.token == "" {
		return false
	}
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if len(header) < len(prefix) || header[:len(prefix)] != prefix {
		return false
	}
	given := header[len(prefix):]
	return given != "" && subtle.ConstantTimeCompare([]byte(given), []byte(b.token)) == 1
}

func (b *Bridge) handleList(w http.ResponseWriter, _ *http.Request) {
	var tools []ToolDescriptor
	for _, id := range b.ids.AdapterIDs() {
		m, err := b.runner.Describe(id)
		if err != nil {
			// A disabled or otherwise unreachable adapter is left off the
			// list rather than failing the whole listing.
			continue
		}
		tools = append(tools, describeTool(m))
	}
	writeJSON(w, http.StatusOK, ToolListResult{Tools: tools})
}

// describeTool turns one adapter's manifest into the wire descriptor the
// agent plans against. The manifest carries no parameter schema of its
// own, so InputSchema is invented here from the one intent shape every
// adapter accepts.
//
// disconnect is appended to every tool's verbs and enum here rather than
// coming from the manifest: it is a bridge-level verb, not a manifest verb —
// it has no plan, so manifest.ParseVerb never sees it, and every adapter
// gets one whether or not its manifest declares a revoke verb of its own.
func describeTool(m manifest.Manifest) ToolDescriptor {
	verbs := make([]VerbDescriptor, 0, len(m.Verbs)+1)
	verbNames := make([]any, 0, len(m.Verbs)+1)
	for _, v := range m.Verbs {
		verbs = append(verbs, VerbDescriptor{Name: string(v), RequiresPreview: v.RequiresPreview()})
		verbNames = append(verbNames, string(v))
	}
	description := "Adapter " + m.ID + "; verbs: "
	for i, v := range m.Verbs {
		if i > 0 {
			description += ", "
		}
		description += string(v)
	}
	description += ", disconnect (undo this app's credentials and consent)"
	verbs = append(verbs, VerbDescriptor{Name: "disconnect", RequiresPreview: true})
	verbNames = append(verbNames, "disconnect")
	return ToolDescriptor{
		Name:        m.ID,
		Description: description,
		Verbs:       verbs,
		Ceiling:     string(m.Ceiling),
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"verb": map[string]any{
					"type":        "string",
					"description": "Which verb to invoke on " + m.ID + ".",
					"enum":        verbNames,
				},
				"subject": map[string]any{
					"type":        "string",
					"description": "Unresolved subject (a contact name, a place, a track title).",
				},
				"handle": map[string]any{
					"type":        "string",
					"description": "Device-resolved handle (phone number, place id, URI).",
				},
				"body": map[string]any{
					"type":        "string",
					"description": "Free-text body for the verb, when it takes one.",
				},
				"fields": map[string]any{
					"type":                 "object",
					"additionalProperties": map[string]any{"type": "string"},
					"description":          "Any additional named fields the verb needs.",
				},
			},
			"required": []any{"verb"},
		},
	}
}

func (b *Bridge) handleCall(w http.ResponseWriter, r *http.Request) {
	var req ToolCallRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		b.logCall(req.Adapter, req.Verb, "bad_request")
		writeJSON(w, http.StatusBadRequest, ToolCallResult{OK: false, Error: &CallError{Code: "bad_request", Message: "body is not valid JSON"}})
		return
	}

	// disconnect is bridge-level, not a manifest verb: it has no plan, so it
	// never reaches ParseVerb or Resolve/Preview.
	if req.Verb == "disconnect" {
		b.handleDisconnectCall(w, r, req)
		return
	}

	verb, err := manifest.ParseVerb(req.Verb)
	if err != nil {
		b.logCall(req.Adapter, req.Verb, "bad_request")
		writeJSON(w, http.StatusBadRequest, ToolCallResult{OK: false, Error: &CallError{Code: "bad_request", Message: "unknown verb"}})
		return
	}

	intent := adapter.Intent{
		AdapterID: req.Adapter,
		Verb:      verb,
		Subject:   req.Subject,
		Handle:    req.Handle,
		Body:      req.Body,
		Fields:    req.Fields,
	}

	plan, err := b.runner.Resolve(r.Context(), intent)
	if err != nil {
		b.respondCallError(w, req.Adapter, req.Verb, err)
		return
	}

	preview, err := b.runner.Preview(r.Context(), plan)
	if err != nil {
		b.respondCallError(w, req.Adapter, req.Verb, err)
		return
	}

	// Recipient is whichever of handle/subject names who this call reaches;
	// handle wins because it is the device-resolved identity, the one the
	// gate store keys recipient history on.
	recipient := req.Handle
	if recipient == "" {
		recipient = req.Subject
	}

	// Irreversible and Revoke are hardcoded false: the current manifest has
	// no irreversible flag (RequiresPreview is a preview concern, not this
	// gate) and no revoke verb is reachable through /call yet. Future
	// adapters set these from their manifests.
	decision, err := b.gate.Policy.Evaluate(gates.CallFacts{
		Adapter:      req.Adapter,
		Verb:         req.Verb,
		Recipient:    recipient,
		TurnKey:      req.TurnKey,
		Irreversible: false,
		AllowListed:  b.gate.AllowListed != nil && b.gate.AllowListed(recipient),
		Revoke:       false,
	})
	if err != nil {
		b.respondCallError(w, req.Adapter, req.Verb, err)
		return
	}

	if !decision.Allow {
		gate := *decision.Gate
		previewSummary := PreviewSummary{Headline: preview.Headline, Lines: preview.Lines, Confirm: preview.Confirm}
		b.pendingMu.Lock()
		b.pending[gate.ID] = pendingCall{plan: plan, preview: preview, adapterID: req.Adapter, recipient: recipient, verb: req.Verb}
		b.pendingMu.Unlock()
		if b.gate.Notifier != nil {
			b.gate.Notifier.GateRaised(gate, previewSummary)
		}
		b.logGateEvent(req.Adapter, req.Verb, "gated", gate.ID)
		writeJSON(w, http.StatusOK, ToolCallResult{
			OK:      false,
			GateID:  gate.ID,
			Preview: &previewSummary,
			Error:   &CallError{Code: "approval_required", Message: gateMessage(gate.Kind)},
		})
		return
	}

	// Every allowed call still runs the preview step and self-confirms it —
	// the hard-gate policy above decides what may be called at all; this is
	// not a second confirmation round-trip through this bridge.
	result, err := b.executeCall(r.Context(), plan, preview, req.Adapter, recipient, req.Verb, "ok")
	if err != nil {
		b.respondCallError(w, req.Adapter, req.Verb, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

// handleDisconnectCall handles the disconnect verb: not a manifest verb, so
// it never reaches ParseVerb, Resolve, or Preview — a disconnect has no
// plan, only an adapter id whose credentials and consent grant get undone.
// It is one of the four hard gates (KindRevoke) and always stops for the
// owner's approval, regardless of the allow list.
func (b *Bridge) handleDisconnectCall(w http.ResponseWriter, r *http.Request, req ToolCallRequest) {
	if b.gate.Disconnector == nil {
		// Misconfiguration — no disconnector wired — fails closed rather
		// than silently no-op'ing a revoke.
		b.logCall(req.Adapter, req.Verb, "adapter_failed")
		writeJSON(w, http.StatusBadGateway, ToolCallResult{OK: false, Error: &CallError{Code: "adapter_failed", Message: "disconnect is not wired"}})
		return
	}

	if b.gate.Disconnector.Disconnected(req.Adapter) {
		// Idempotent repeat: the connection is already undone, so there is
		// nothing left to approve.
		b.logCall(req.Adapter, req.Verb, "ok")
		writeJSON(w, http.StatusOK, ToolCallResult{OK: true, Done: true, Detail: "already disconnected"})
		return
	}

	if _, err := b.runner.Describe(req.Adapter); err != nil {
		b.respondCallError(w, req.Adapter, req.Verb, err)
		return
	}

	decision, err := b.gate.Policy.Evaluate(gates.CallFacts{
		Adapter: req.Adapter,
		Verb:    "disconnect",
		TurnKey: req.TurnKey,
		Revoke:  true,
	})
	if err != nil {
		b.respondCallError(w, req.Adapter, req.Verb, err)
		return
	}

	// Revoke is always gated, so decision.Allow is always false here, but
	// this mirrors the gated branch in handleCall rather than assuming it.
	gate := *decision.Gate
	preview := execution.Preview{Preview: adapter.Preview{
		Headline: "Disconnect " + req.Adapter,
		Confirm:  "Disconnect",
	}}
	previewSummary := PreviewSummary{Headline: preview.Headline, Lines: preview.Lines, Confirm: preview.Confirm}
	b.pendingMu.Lock()
	b.pending[gate.ID] = pendingCall{preview: preview, adapterID: req.Adapter, verb: "disconnect"}
	b.pendingMu.Unlock()
	if b.gate.Notifier != nil {
		b.gate.Notifier.GateRaised(gate, previewSummary)
	}
	b.logGateEvent(req.Adapter, req.Verb, "gated", gate.ID)
	writeJSON(w, http.StatusOK, ToolCallResult{
		OK:      false,
		GateID:  gate.ID,
		Preview: &previewSummary,
		Error:   &CallError{Code: "approval_required", Message: gateMessage(gate.Kind)},
	})
}

// executeCall runs plan to completion and marks its recipient known on
// success. It is the one place that actually calls the adapter, shared by
// the direct-allow path in handleCall and by ApproveGate, so both produce
// the same result shape and the same known-recipient bookkeeping.
func (b *Bridge) executeCall(ctx context.Context, plan adapter.Plan, preview execution.Preview, adapterID, recipient, verb, outcome string) (ToolCallResult, error) {
	out, err := b.runner.Execute(ctx, plan, preview.Confirmed())
	if err != nil {
		var work *adapter.DeviceWorkError
		if errors.As(err, &work) {
			return b.runOnDevice(ctx, work, preview, adapterID, recipient, verb)
		}
		return ToolCallResult{}, err
	}
	if verb != "read" && recipient != "" {
		// A failure here means real work already happened and only the
		// bookkeeping about it failed — that must never be reported back as
		// a call failure, so it is logged and swallowed, not returned.
		if markErr := b.gate.Store.MarkRecipientMessaged(adapterID, recipient); markErr != nil {
			b.logger.Error("[agent-bridge] mark recipient known failed", "adapter", adapterID, "verb", verb, "error", markErr.Error())
		}
	}
	b.logCall(adapterID, verb, outcome)
	return ToolCallResult{
		OK:          true,
		Reached:     string(out.Reached),
		Done:        out.Done,
		HandedOffTo: out.HandedOffTo,
		Detail:      out.Detail,
		Preview: &PreviewSummary{
			Headline: preview.Headline,
			Lines:    preview.Lines,
			Confirm:  preview.Confirm,
		},
	}, nil
}

// runOnDevice carries a DeviceWorkError the rest of the way: hand its Ask to
// the phone through the wired DeviceWorker and wait for the answer inside
// this same tool call. No phone wired in, or the phone's own error, both
// come back as a plain error — respondCallError turns either into
// adapter_failed. An unanswered ask is not one of those: it is a Result
// like any other, reported OK with Done false, because the reply may
// already be sitting in someone's chat and "failed" would invite a retry.
func (b *Bridge) runOnDevice(ctx context.Context, work *adapter.DeviceWorkError, preview execution.Preview, adapterID, recipient, verb string) (ToolCallResult, error) {
	if b.gate.DeviceWorker == nil {
		return ToolCallResult{}, fmt.Errorf("agentbridge: %s needs a phone to finish %s, but none is connected", adapterID, work.Kind)
	}
	deviceCtx, cancel := context.WithTimeout(ctx, devicework.Timeout)
	defer cancel()
	result, err := b.gate.DeviceWorker.RunOnDevice(deviceCtx, devicework.Ask{
		AdapterID: work.AdapterID,
		Kind:      work.Kind,
		Handle:    work.Handle,
		Text:      work.Text,
		Ceiling:   work.Ceiling,
	})
	if err != nil {
		return ToolCallResult{}, fmt.Errorf("agentbridge: device work for %s failed: %w", adapterID, err)
	}
	if verb != "read" && recipient != "" {
		if markErr := b.gate.Store.MarkRecipientMessaged(adapterID, recipient); markErr != nil {
			b.logger.Error("[agent-bridge] mark recipient known failed", "adapter", adapterID, "verb", verb, "error", markErr.Error())
		}
	}
	b.logCall(adapterID, verb, "ok")
	return ToolCallResult{
		OK:      true,
		Reached: string(result.Reached),
		Done:    result.Done,
		Detail:  result.Detail,
		Preview: &PreviewSummary{
			Headline: preview.Headline,
			Lines:    preview.Lines,
			Confirm:  preview.Confirm,
		},
	}, nil
}

// gateMessage is the short, human-readable reason sent back to the agent
// alongside code approval_required, naming the kind of gate that stopped
// the call.
func gateMessage(kind gates.Kind) string {
	switch kind {
	case gates.KindFirstContact:
		return "first message to this recipient needs owner approval"
	case gates.KindRevoke:
		return "revoking access needs owner approval"
	case gates.KindIrreversible:
		return "this irreversible action needs owner approval"
	case gates.KindExfiltration:
		return "sending after reading another adapter this turn needs owner approval"
	case gates.KindUnlistedSend:
		return "sending to someone not on the allow list needs owner approval"
	default:
		return "this call needs owner approval"
	}
}

// ApproveGate releases a pending gate and runs the call it was blocking,
// exactly once. The pending entry is popped before Execute runs, mirroring
// Policy.Approve's one-shot pattern, so a second approval of the same id
// can never execute the call again.
func (b *Bridge) ApproveGate(ctx context.Context, gateID string) (ToolCallResult, error) {
	if _, ok := b.gate.Policy.Approve(gateID); !ok {
		return ToolCallResult{}, fmt.Errorf("agentbridge: gate %q is not pending", gateID)
	}
	b.pendingMu.Lock()
	call, exists := b.pending[gateID]
	if exists {
		delete(b.pending, gateID)
	}
	b.pendingMu.Unlock()
	if !exists {
		// The policy released a gate this bridge never stored a call for —
		// a bug in this package, not a caller error.
		return ToolCallResult{}, fmt.Errorf("agentbridge: gate %q approved but has no pending call", gateID)
	}
	if call.verb == "disconnect" {
		// A disconnect has no plan to execute — it runs the disconnector
		// directly and never touches MarkRecipientMessaged, since there is
		// no recipient.
		if err := b.gate.Disconnector.Disconnect(ctx, call.adapterID); err != nil {
			return ToolCallResult{}, err
		}
		b.logCall(call.adapterID, call.verb, "approved")
		return ToolCallResult{
			OK:      true,
			Reached: "completes",
			Done:    true,
			Preview: &PreviewSummary{Headline: call.preview.Headline, Lines: call.preview.Lines, Confirm: call.preview.Confirm},
		}, nil
	}
	return b.executeCall(ctx, call.plan, call.preview, call.adapterID, call.recipient, call.verb, "approved")
}

// DenyGate drops the pending call and durably records the denial so the
// gate can never release, even across a restart.
func (b *Bridge) DenyGate(gateID string) error {
	b.pendingMu.Lock()
	call, exists := b.pending[gateID]
	delete(b.pending, gateID)
	b.pendingMu.Unlock()
	if err := b.gate.Policy.Deny(gateID); err != nil {
		return err
	}
	if exists {
		b.logGateEvent(call.adapterID, call.verb, "denied", gateID)
	}
	return nil
}

// logGateEvent records a gate lifecycle line — adapter, verb, outcome, and
// the gate id, never the recipient or call body.
func (b *Bridge) logGateEvent(adapterID, verb, outcome, gateID string) {
	b.logger.Info("[agent-bridge] gate", "adapter", adapterID, "verb", verb, "outcome", outcome, "gate_id", gateID)
}

// respondCallError maps a resolve/preview/execute error onto the closed set
// of CallError codes and writes the ToolCallResult envelope even on
// failure, since the OpenClaw plugin decodes that envelope on every path.
func (b *Bridge) respondCallError(w http.ResponseWriter, adapterID, verb string, err error) {
	var status int
	var code string
	switch {
	case errors.Is(err, registry.ErrUnknownAdapter), errors.Is(err, registry.ErrAdapterDisabled):
		status, code = http.StatusNotFound, "unknown_adapter"
	case errors.Is(err, execution.ErrVerbNotOffered):
		status, code = http.StatusBadRequest, "verb_not_offered"
	default:
		status, code = http.StatusBadGateway, "adapter_failed"
	}
	b.logCall(adapterID, verb, code)
	writeJSON(w, status, ToolCallResult{OK: false, Error: &CallError{Code: code, Message: err.Error()}})
}

// logCall records one line per call — adapter, verb, and outcome only.
// Never the token, the call body, or a handle: those can carry a phone
// number or message text, exactly what this line must not leak into logs.
func (b *Bridge) logCall(adapterID, verb, outcome string) {
	b.logger.Info("[agent-bridge] call", "adapter", adapterID, "verb", verb, "outcome", outcome)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
