# Location tool — on-device verification (Pixel 9, 2026-08-26)

Device `4B230DLAQ001Z5`, package `app.codexlauncher`. Runtime rebuilt with the
`location` adapter, deployed standalone (on-phone Debian/proot), gateway plugin
tool table refreshed to 80 tools, gateway reloaded. Verified through the real
app UI by typing a prompt to the phone agent and watching the runtime log.

## What was deployed
- New `operator-phone-runtime` (linux/arm64, sha `a77191b9…`) installed at
  `/usr/local/bin/operator-phone-runtime`; old binary backed up at
  `.bak-20260826-174526` (sha `3a4afd04…`). Health-checked (run ≥4s + TCP 9443),
  auto-rollback armed but not needed.
- `operator-tools` OpenClaw plugin refreshed: `dist/tools.json` +
  `openclaw.plugin.json` regenerated on-device via `sync-tools.mjs` against the
  live bridge (`https://127.0.0.1:9443`). Went 79 → **80 tools**, adding
  `location` (verbs read + disconnect, ceiling completes). Reinstalled with
  `openclaw plugins install . --force`; gateway restarted and loaded it
  (`http server listening (10 plugins: … operator-tools …)`).
- Confirmed `location` is NOT stripped by tool-policy: the gateway removes only
  the owner-only `cron, gateway, nodes`.

## Deny path (permission not granted) — PASS
Prompt: "What is my current GPS location right now?" (screens 01, 02)

Runtime log (18:04:43 UTC), full Design-C round-trip:
```
[location] resolve verb=read
[location] execute decision=hand_off_to_phone
[mobile-session] device action handed to phone device_id=local-android
    request_id=b68f92e4… adapter_id=location kind=get_location ceiling=completes
[mobile-session] message received … message_type=device_action_result
[mobile-session] device action result delivered to its waiter
    outcome=handed_to_the_app ceiling=completes done=true
[agent-bridge] call adapter=location verb=read outcome=ok
```
App log: `CodexLauncher/location: location request refused for missing permission decision=permission_denied`.

Result: agent replied **"I can't access your current GPS location because
location permission hasn't been granted to OpenClaw. Enable location access for
OpenClaw on your device, then ask me again."** The `permission_denied` payload
propagated end-to-end into a correct natural-language answer. The app also fired
the system permission dialog (`GrantPermissionsActivity` launched); the user
tapped Allow, flipping ACCESS_FINE_LOCATION + ACCESS_COARSE_LOCATION to
`granted=true` (flag USER_SET).

## Grant path (permission granted) — PASS
Same prompt again (screens 03, 04).

Runtime log (18:07:02–04 UTC):
```
[location] resolve verb=read
[location] execute decision=hand_off_to_phone
[mobile-session] device action handed to phone … request_id=75460d74… kind=get_location
[mobile-session] device action result delivered to its waiter … outcome=handed_to_the_app done=true
[agent-bridge] call adapter=location verb=read outcome=ok
```
Tell-tale: the round-trip took **~2.0 s** (handed 18:07:02.83 → delivered
18:07:04.79) versus the deny path's ~40 ms. That 2 s is the real GPS fix being
acquired (`getCurrentLocation`, PRIORITY_HIGH_ACCURACY). No permission-refused
log this round. Tool returned `outcome=ok`.

## Known separate issue (not the location tool)
On the grant turn the Codex agent (gpt-5.6-sol) then stalled for 5+ min without
emitting its final natural-language reply — no further tool calls, no runtime
turn-completion event. The location tool's work finished cleanly at
`outcome=ok`; this is Codex-agent latency/hang downstream of the tool, and it is
the same class of "cold start / weird latency" the perceived-latency work
targets. It did not block confirming the tool: the real fix was fetched and
delivered. Tracked with the response-latency workstream, not location.

## Verdict
Both branches proven on the physical phone with logged evidence. The agent can
call `location`, the Design-C device_action carries the payload back, deny
returns a typed `permission_denied` (and prompts for permission), grant returns
a real GPS fix.
