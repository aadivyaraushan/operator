// Package getlocation is the adapter that answers "where is the phone right
// now" by asking Android's location API.
//
// Every other adapter in this tree finishes the whole job itself, on the
// Mac. This one cannot: the Mac has no GPS, no fused location provider, and
// no way to ask the OS for a fix — only the phone does. So Resolve does the
// ordinary job of checking the request makes sense, and Execute does what
// notificationreply's Execute does — it refuses to act, and instead hands
// the decision to the phone by returning an *adapter.DeviceWorkError. The
// chain that carries that error to the phone and back already exists and
// already works (see notificationreply/adapter_test.go for the full path);
// this file is a second thing that starts it.
package getlocation

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/codex-launcher/codex-launcher/companion/internal/capability/adapter"
	"github.com/codex-launcher/codex-launcher/companion/internal/capability/manifest"
)

const (
	// ID is how the registry, the router and the inventory all name this
	// adapter.
	ID = "location"

	// deviceWorkKind is the value the phone matches against when it decides
	// what kind of device work it was handed (contract/validation.go's
	// knownDeviceActionKind). It is written down separately from ID even
	// though the two answer related questions, because they answer
	// different ones: ID is how this adapter is addressed on the Mac,
	// deviceWorkKind is a word on the wire the phone depends on staying
	// exactly this — see notificationreply.deviceWorkKind for the same
	// split under the same reasoning.
	deviceWorkKind = "get_location"
)

type Adapter struct {
	logger *slog.Logger
}

var _ adapter.Adapter = (*Adapter)(nil)

func New(logger *slog.Logger) *Adapter {
	if logger == nil {
		logger = slog.Default()
	}
	return &Adapter{logger: logger}
}

func (a *Adapter) Describe() manifest.Manifest {
	return manifest.Manifest{
		ID: ID, Runtime: manifest.RT2,
		Verbs:   []manifest.Verb{manifest.Read},
		Ceiling: manifest.Completes, Consent: manifest.ConsentA,
		Auth: manifest.AuthNone, Cost: manifest.CostFree,
		Gates:    []manifest.Gate{manifest.GateNone},
		Capacity: manifest.Capacity{Kind: manifest.CapacityNone},
		Region:   []string{"global"}, Platform: manifest.PlatformAndroid,
		ProvesCeiling: "location_get_location_smoke",
	}
}

// Resolve checks the request makes sense and builds the plan Execute will
// hand to the phone. There is no subject or handle to validate — a location
// read names nothing but itself.
func (a *Adapter) Resolve(_ context.Context, in adapter.Intent) (adapter.Plan, error) {
	a.logger.Info("[location] resolve", "verb", in.Verb)

	if in.Verb != manifest.Read {
		return adapter.Plan{}, fmt.Errorf("getlocation: verb %q is not supported; use read", in.Verb)
	}

	return adapter.Plan{
		AdapterID: ID, Verb: manifest.Read,
		Handle:  "current_location",
		Summary: "Read the device's current location",
	}, nil
}

func (a *Adapter) Preview(_ context.Context, plan adapter.Plan) (adapter.Preview, error) {
	return adapter.Preview{Plan: plan, Headline: plan.Summary, Confirm: "Read location"}, nil
}

// Execute never talks to anything itself. It hands the plan to the phone by
// returning a DeviceWorkError — the signal handleDeviceAction on the phone
// is already built to receive.
func (a *Adapter) Execute(_ context.Context, plan adapter.Plan) (adapter.Outcome, error) {
	a.logger.Info("[location] execute", "decision", "hand_off_to_phone")
	return adapter.Outcome{}, &adapter.DeviceWorkError{
		AdapterID: ID,
		Kind:      deviceWorkKind,
		// validateBody's "device_action" case (validation.go) requires
		// handle to pass safeDisplayString (non-blank, no control chars)
		// and text to be non-blank; the phone's mirrored validator enforces
		// the same rule on decode. A blank Handle/Text would fail that
		// check and the frame would never reach the phone — the agent's
		// call would just time out after 60s with no error. Neither field
		// is read by the phone for get_location (its handler calls the
		// location API and ignores both), so any legible placeholder is
		// safe; these come from Resolve's plan rather than being
		// hardcoded here.
		Handle:  plan.Handle,
		Text:    plan.Summary,
		Ceiling: manifest.Completes,
	}
}

func (a *Adapter) Revoke(context.Context) error {
	a.logger.Info("[location] revoke", "decision", "noop_no_credentials")
	return nil
}
