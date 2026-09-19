# Clean UTM SE guest scaffold

This folder defines inputs for a fresh x86_64 Alpine 3.22.5 guest. It does not
include an image, an SSH key, a password, a provider credential, or a gateway
token. In particular, do not copy the temporary proof qcow2 into a build or
release artifact.

## Inputs and outputs

- `image-build/build-clean-image.sh` takes the pinned clean Alpine qcow2, verifies
  its full SHA-512 from `definition/manifest.env`, and writes a new 4 GB virtual
  qcow2. It never downloads an image and refuses to overwrite an output.
- `first-boot/provision-guest.sh` runs in that fresh guest and takes one checked
  runtime payload. The payload digest and byte size are pinned in the manifest;
  it contains Node 22.23.2, OpenClaw 2026.9.1, and the matching SQLite 3.53.4
  runtime. Fourteen signed Alpine dependency packages are pinned by SHA-256 and
  installed with networking disabled. The same Node SQLite API used by OpenClaw
  proves the exact SQLite version, WAL mode, and a write/read round trip.
- `runtime-start/inject-runtime-token.sh` starts one command with a caller-provided token. It
  briefly uses `/run/openclaw/runtime.env`, removes that file before `exec`, and
  writes no token to persistent guest storage.

Example build:

```sh
./image-build/build-clean-image.sh alpine-clean.qcow2 out/operator-clean.qcow2
```

Example guest provisioning with locally verified artifacts:

```sh
./first-boot/provision-guest.sh operator-openclaw-runtime-2026.9.1-r3.tar.gz runtime-apks/
```

## Current runtime proof

The provisioned configuration disables OpenClaw's browser dashboard with
`gateway.controlUi.enabled: false`. Operator uses native chat, so preparing or
building that dashboard is unnecessary work. Gateway HTTP/WebSocket service and
token authentication remain enabled. This setting is tested in the source
configuration; its timing benefit has not yet been measured on a rebuilt guest.

Gateway stdout and stderr are captured in `/run/openclaw/stdout.log` and
`/run/openclaw/stderr.log`, with directory mode 0700 and file mode 0600 owned by
the Gateway account. OpenClaw's built-in startup trace records startup stages
and timing. These logs are guest-local and volatile across a cold boot; do not
export them without checking for sensitive output. They can survive a VM
snapshot. This replaces discarded startup output, not OpenClaw's own log files.

The service supplies OpenClaw's `--disable-warning=ExperimentalWarning` through
`NODE_OPTIONS` before starting Node, preserving any existing Node options. The
pinned launcher otherwise starts another process to add this flag. Certificate
setup is not bypassed: `OPENCLAW_NO_RESPAWN` is not enabled. The embedded Node
22.23.2 accepted this option with exit 0; startup savings are not yet measured.

The service sets `NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache`, creating
that directory with mode 0700 owned by the Gateway account before launch.
OpenClaw's pinned launcher scopes its cache by package version and installation
metadata. Unlike the temporary default, this directory survives cold guest
boots. The first run still needs to create the cache; no precomputed cache is
bundled and no iOS startup improvement has been measured. Certificate handling
and available capabilities are unchanged.

The pairing shell waits for guest-local `/healthz` using BusyBox wget before
replacing itself with one Node process. That process imports the installed public
`openclaw/plugin-sdk/device-bootstrap` entry and uses upstream list/approve APIs.
It does not launch the full CLI for each check or write the SQLite store directly.

Only pending requests with the injected device ID **and** public key can be
approved. Ambiguous matches and roles other than operator/node are rejected.
Pending upgrades take priority over already paired roles. A disappeared request
is retried by listing again; no implicit latest-request selection is used.
Completion requires a fresh list with both roles and no matching pending request.
List and approve remain separate API calls, as in the previous CLI route;
this is not a new atomic identity-conditioned approval API.

HUP, INT and TERM exit with 129, 130 and 143. Parent exit and exhausted attempts
exit with 75. Progress and failures stay in the owner-only
`/run/openclaw/app-device-error.log`; no tokens or complete pairing records are
logged. The file is reset on startup and is not size-rotated.

Focused tests cover identity/role selection, stale requests, signals, shell
health gating and private log permissions. The pinned SDK integration test
creates temporary synthetic state, approves operator then node through the real
API, and leaves an unrelated device pending. This is Mac execution evidence,
not iOS performance or live account proof. Run it explicitly with
`OPERATOR_TEST_OPENCLAW_PACKAGE=/path/to/pinned/openclaw node --test ios/Runtime/tests/startup/pairing-sdk-integration.test.mjs`
from the repository root; without that path the integration test is skipped.

The native UTM overlay passes a one-launch token and the app's exact signed
device identity through three protected launch files, converts them to QEMU
`fw_cfg` inputs, deletes the launch files after VM start, and keeps the token out
of the VM bundle. The exact production image has booted in QEMU on macOS with
those protected values. OpenClaw loaded with no plugin errors and its
authenticated loopback Gateway health check returned `ok: true`. The base qcow2
was then checked with `qemu-img check`, which found no errors.

This proves the guest, runtime, launch values, and loopback Gateway in macOS
QEMU. It does not prove the UTM iOS host, app lifecycle, speed, or token cleanup
on a physical iPhone; those checks still require Apple runtime access.

Before treating this as a supported iPhone runtime, physically verify that UTM
can boot the image inside Operator, the Gateway responds over the app's loopback
forward, and save/stop/restart survives the desired foreground/resume flow
without persisting the token or sending an action twice.
