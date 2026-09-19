//go:build ignore

// A backup copy kept as evidence, not a package anyone builds. It imports
// companion/internal/phoneruntime, which Go forbids from outside companion/,
// so `go test ./...` has failed on it since it was saved here — including on
// main, in CI, continuously. Excluded rather than deleted because
// saved-results/ exists to keep records.

package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/codex-launcher/codex-launcher/companion/internal/phoneruntime"
	"github.com/codex-launcher/codex-launcher/companion/internal/phoneruntime/localtrust"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) > 0 && args[0] == "pair-android" {
		return runPairAndroid(args[1:])
	}
	fs := flag.NewFlagSet("operator-phone-runtime", flag.ContinueOnError)
	root := fs.String("root", "", "no-backup state root for phone-runtime identities and session store")
	listen := fs.String("listen", phoneruntime.ListenAddress, "fixed loopback listen address")
	name := fs.String("name", "Operator phone", "display name shown in the mobile session")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *root == "" {
		fmt.Fprintln(os.Stderr, "operator-phone-runtime: -root is required")
		return 2
	}
	absRoot, err := filepath.Abs(*root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "operator-phone-runtime: resolve root: %v\n", err)
		return 1
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	runtime, err := phoneruntime.Open(ctx, phoneruntime.Config{
		Root:          absRoot,
		DisplayName:   *name,
		ListenAddress: *listen,
	}, phoneruntime.Dependencies{Random: rand.Reader, Logger: logger})
	if err != nil {
		fmt.Fprintf(os.Stderr, "operator-phone-runtime: open: %v\n", err)
		return 1
	}
	defer runtime.Close()

	logger.Info("[phone-runtime] serve starting", "mode", runtime.Health().Mode, "process", runtime.Health().Process, "listen", runtime.Health().ListenAddress)
	if err := runtime.Serve(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "operator-phone-runtime: serve: %v\n", err)
		return 1
	}
	return 0
}

func runPairAndroid(args []string) int {
	fs := flag.NewFlagSet("pair-android", flag.ContinueOnError)
	out := fs.String("out", "", "path for the public offer JSON (0600); secret never written")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *out == "" {
		fmt.Fprintln(os.Stderr, "pair-android: -out is required")
		return 2
	}
	offer, err := localtrust.NewOffer(localtrust.OfferParams{Port: 9443, ExpiresIn: 10 * time.Minute, Now: time.Now().UTC()})
	if err != nil {
		fmt.Fprintf(os.Stderr, "pair-android: create offer: %v\n", err)
		return 1
	}
	raw, err := json.MarshalIndent(offer.Public, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "pair-android: encode: %v\n", err)
		return 1
	}
	if err := os.WriteFile(*out, raw, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "pair-android: write: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "pair-android: wrote public offer id=%s mime=%s (secret retained in memory only for this process)\n", offer.Public.OfferID, localtrust.MimeType)
	_ = offer.Secret
	return 0
}
