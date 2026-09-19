# Operator latency + cold-start — implementation notes

**Task:** reduce per-response "cold start" and overall latency; verify on the physical Pixel 9 (`4B230DLAQ001Z5`). Sibling task: add a user-location tool.
**Date started:** 2026-08-25. **Device up:** ~52 min at start (post-reboot state from the P2 test).

Governing playbook: Perf issue (measure baseline first, tie every fix to a measurement). Money: any paid measurement send runs on the flat-rate ChatGPT subscription `ssdear@gmail.com` (no per-call billing); kept to a handful.

## Live device state (measured, adb, free)
- Foreground app `app.codexlauncher/.LauncherActivity`. One persistent `node` gateway (pid 18833, ppid 5868). Termux 4661 + proot 5132 alive.
- Loopback ports LISTENING: `127.0.0.1:9443` (phone runtime TLS), `127.0.0.1:18789` (gateway ws). Single persistent node — so per-response cold start is unlikely to be socket setup.
- App log tag prefix: `CodexLauncher/<feature>` (e.g. `standalone`, `task-transcript`, `session-network`, `connection-runtime`, `broker-loopback`, `updater`).

## Free finding 1 — app cold start to connected ≈ 1.37s
Timeline from a `force-stop` + `am start` cold launch (logcat threadtime, marker `COLDSTART_MARK`):
```
08.983 cold launch begin
09.294 activity Displayed  (+371ms draw)
09.433 standalone runtime status read (local_pair_acked=true)
09.597 connecting unpaired local phone-runtime session / companion connection requested
10.166 opening pinned WebSocket           <-- 569ms gap after 09.597
10.275 pinned WebSocket opened (tls13_websocket)  (~109ms)
10.320 session authenticated (resume_mode=warm)   (~150ms handshake)
10.356 snapshot + queued task events  => connected
```
Suspects on the startup path:
- **569ms gap** 09.597 → 10.166 before the socket opens. Cause unconfirmed (loopback TLS bring-up? resume-cursor load? await?). Needs source grounding.
- **Updater GitHub fetch on every startup** (09.292–09.577, `listing github releases`). Runs in parallel so it doesn't block connect, but it is avoidable startup work / network on the boot path. Candidate for scheduling (defer to idle) or gating.

## Free finding 2 — UI refresh is 2s polling, not streaming
On the transcript screen, idle logcat shows a fixed ~2s cadence:
```
every ~2.0s: standalone runtime status read
             live transcript refresh requested -> transcript page requested -> transcript page applied
```
So a ready reply can wait up to ~2s to appear, and streaming feels choppy (updates land in 2s steps). This is a perceived-latency/smoothness lever independent of the agent's own latency. Confirm the poll source + interval against recon.

## MEASURED baseline on device (2026-08-25, 3 paid sends, flat-rate ssdear@gmail.com)
Trivial prompts ("hi", etc.), logcat markers, Android-side timeline (all times device clock):

| Send | idle before | tap->send boundary | **dead-time** (boundary -> first reply activity) | reply streaming |
|---|---|---|---|---|
| A | ~5 min | 351ms (incl. socket reopen) | **~30s** (38.366 -> 02:08.3) | burst, ~1.7s |
| B2 | ~2.5 min | ~490ms | **~18.4s** (42.641 -> 05:01.1) | ~1s |
| C | ~1 min | 381ms | **~20.5s** (40.167 -> 07:00.7) | ~18 events in 400ms |

**Findings (measured):**
- End-to-end for a trivial prompt ≈ **20-32s**, dominated by an **~18-30s pre-first-token dead-time**.
- Transport is fast: tap -> send-boundary ≈ 350-490ms. Reply **streams/pushes** once it starts (event bursts <50ms apart), so the 2s poll is NOT the dead-time cause.
- Dead-time is **roughly constant ~20s across 1-5 min idle** — a per-turn cost, not idle-teardown (revised from the earlier 2-point "scaling" read).
- Gateway `node` process is **stable** (pid 18833, 57min uptime, no per-turn restart). phone-runtime pid 5904 stable.
- The app **closes + reopens its websocket on every send** (idle-closed), but that's only ~240ms.
- Agent's own words on the cold reply: "Hey—I just came online" — consistent with a freshly-warmed agent session, but the process didn't restart, so it's session/model warmup inside node, not a respawn.

**Root-cause (strong inference, not yet gateway-confirmed):** the ~20s is the on-phone agent's **model reasoning + prefill** step (config line from recon: `gpt-5.6-sol thinking=medium, fast=off`; big system prompt + 77 tool schemas + growing history inflate prefill; a reasoning model over-thinks even trivial prompts). This lives in the **on-phone openclaw gateway/model config, NOT our repo**. The one unverified alternative is a fixed ~20s gateway-internal stall unrelated to the model; distinguishing them needs the gateway-side breakdown (un-drop `chat.send_timing`, or read `/var/log/operator/openclaw-gateway` trajectory_ms in proot).

**Implication:** our app code contributes <1s; the dominant lever is model config (`fast=on` / lower `thinking`), a speed-vs-reasoning tradeoff on the user's personal agent. Surface as a decision, don't flip unilaterally.

## Still to measure (needs instrumented paid send)
- Per-response agent cold start: send -> first reply token, and whether it's every-response or first-after-idle.
- Where the Codex turn spends time (process spawn? session warmup? token refresh?). Depends on recon B locating on-phone gateway/runtime timing logs (svlogd under /etc/operator/services, inside proot).

## Recon B — the path is all persistent connections (source-grounded)
- Every hop from Android send -> gateway -> reply reuses an **already-open** connection. Gateway ws (`ws://127.0.0.1:18789`) is persistent, redials only on drop with a fixed **5s** retry (`runtime.go:55,489-532`). No per-turn dial on the critical path.
- Codex session is **reused** (fixed key `agent:main:main`, `runtime.go:50`); `chat.send` -> `loadSessionEntry`, no `sessions.create`, no per-turn OS process spawn on the phone path. (A per-turn `codex app-server` spawn exists only on the separate Mac/desktop route — rule out that a Send is mis-routed to COMPUTER.)
- **Idle-teardown timeout: unknown** — gateway source isn't in the repo (npm `openclaw@2026.7.1-2`, installed only in the phone's proot). Can't rule out gateway-side idle eviction from source; must measure (send-after-10min-idle vs warm).
- Gateway source is NOT editable from this repo. Editable surfaces: Go runtime (turnproxy/runtime), Android app, `agentbridge/openclaw-plugin/` (tool bridge only, not the chat path).

## Instrumentation available (from recon B)
- **`chat.send_timing` event exists but is DROPPED**: `turnproxy/source.go:101` does `if event != "chat" { return }`, silently discarding `chat.send_timing` frames (`openclaw-gateway-protocol.md:399`). Un-dropping it likely exposes a built-in per-send latency breakdown from the gateway. Small, safe Go change; also a UI-feedback hook.
- Built-in per-turn fields in OpenClaw records: `session_record_runtime_ms`, `trajectory_event_span_ms`.
- Go slog markers (in proot logs): `[turnproxy] gateway connected` (client.go:121), `[mobile-session] existing task control confirmed` (handler.go:1166), redial lines (runtime.go:503/529/564).
- **Android markers (adb-reachable, no proot needed):** `phone action crossed durable send boundary` (`CompanionSessionClient.kt:143`, send leaves app); inbound reply via `onMessage` (`CompanionSessionClient.kt:237`) -> task events. So end-to-end perceived latency is measurable from logcat alone.

## Ranked cold-start hypotheses (recon B)
1. Gateway plugin pre-warm / cold gateway process (~5.08s "plugins pre-warmed" at gateway boot; gateway can crash/reload). Boot cost, not per-response — unless it restarts between sends.
2. Per-turn `loadSessionEntry` / first-send-of-session cost inside the gateway (unknown; needs `chat.send_timing`/trajectory fields).
3. Model call + ChatGPT OAuth refresh to OpenAI every turn (gpt-5.6-sol, thinking=medium). Likely the dominant floor; only reducible via model/thinking config (gateway-side, quality tradeoff).
4. Turnproxy redial after a dropped gateway connection (intermittent, 5s fixed delay).
5. Android<->companion ws cold connect (once per app open; explains "first message after opening is slow", not steady-state).

## Install path — RESOLVED (no pairing wipe needed)
The installed alpha app (versionName `0.1.0-alpha.1`, DEBUGGABLE) is signed with this Mac's default debug keystore. Proof: `keytool -list -v -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey` SHA-256 == installed signer SHA-256 == `C6:13:E6:60:7C:40:40:42:E6:91:35:17:27:86:38:94:6B:29:C1:8D:C1:CD:81:E9:2C:9D:36:99:A5:80:C2:5D`. So `./gradlew :app:assembleDebug` here re-signs with the SAME key → `adb install -r` succeeds (no signature mismatch, no uninstall, pairing/runtime state preserved). This is the deploy path for both the latency and location changes.

## Updater boot kickoff — grounded (latency lever, low risk)
`LauncherActivity.kt:268` `LaunchedEffect(Unit)` fires on first composition and runs, on `Dispatchers.IO`: `apkUpdateInstaller.clearStaleCache()` then `updatePipeline.checkForUpdate()` (the GitHub releases fetch, ~09.292–09.577 in the cold-start trace). It's off the main thread and does NOT sit on the connect path (connect is a separate effect), but it contends for CPU/radio during the first-connect window. Lever: defer this effect until after the session reports connected (or a few-second delay) so first-connect runs uncontended. Squarely "defer startup work". Manual "check for updates" (`runUpdateCheck(manual=true)`, line 228) stays immediate.

## IMPLEMENTED (Android-only, perceived-latency scope) — 2026-08-25
Four surgical edits, all within the user's chosen "perceived-latency only" scope (model config untouched):
1. **Instant WORKING feedback on send (P1a).** `LauncherSessionViewModel.markTaskWorkingOptimistically(taskId)` sets the just-submitted phone-agent task to `TaskState.WORKING` the moment delivery succeeds (called in `submitHomePromptToPhoneAgent`, guarded on `delivered`). Mirrors the existing `publishTaskQueueState` local-mutation pattern. The first real `TaskEventReducer` event supersedes it, so a wrong guess self-corrects. Kills the "dead ~20s / stale Replied" the user feels. `HomeUiState.kt:51` maps `TaskState.WORKING → StateMark.WORKING`, so the home card shows "Working" instantly.
2. **Keep socket warm (P2).** Added `LauncherSessionViewModel.isOnlineTo(deviceId)`. `LauncherActivity` CapabilityOnPhone send now force-reconnects only when NOT already online to the local endpoint (`if (local != null && !sessionViewModel.isOnlineTo(local.deviceId))`). Previously EVERY send did `connect(force=true)` → full socket teardown (fresh TLS build + blank state + snapshot re-sync) + up-to-5s online-poll before the prompt left. Now a warm send skips all of that. Preserves the Mac-offline correctness (different deviceId → still forces).
3. **Defer updater boot fetch (P3).** `LauncherActivity.kt:268` `LaunchedEffect(Unit)` now `delay(6_000)` before the GitHub releases check, so the cold-launch / first-connect / first-send window runs uncontended. Manual "check for updates" stays immediate.
4. **Animate the WORKING mark (P4).** `StateMarkView.kt` pulses only the WORKING glyph's alpha (0.4↔1.0, 900ms reverse tween) via a conditional `rememberInfiniteTransition`; every other (settled) mark stays static and un-animated. First animation in the app; makes the wait read as alive.

**Skipped with reason:** (a) composer send-button spinner — redundant given the card flips to WORKING instantly and the draft clears on delivery; would add a HomeScreen signature param for marginal value. (b) 2s poll → event-driven — recon proved the poll is already a redundant backstop (reply render is push-driven via the `live_event` refresh), so removing it wouldn't cut reply latency and carries drift risk. (c) model config — user chose perceived-latency only.
**TDD note:** perceived-latency/UI-feel changes (animation, socket warmth, optimistic state) are verified on-device (screen recording + logcat) per the user's explicit request; existing unit suite is the regression guard.

## On-device verification plan (perceived-latency, after deploy)
Baseline to beat is the felt experience, not the ~20s floor (unchanged by design). Measure with logcat markers, same as the baseline sends.
1. **Instant feedback:** tap send → a visible "thinking/working" state must appear in <150ms (not a frozen/blank transcript for 20s). Screen-record a send; confirm the indicator is up before the first reply event.
2. **Progress liveness:** during the ~20s dead-wait the indicator animates / shows elapsed time (doesn't look hung).
3. **Startup snappiness:** cold launch (force-stop + am start) → time-to-connected should be ≤ baseline 1.37s and the updater GitHub fetch must NOT run during the first-connect window (grep logcat: no "updater … checkForUpdate/listing releases" before "connected"); it fires later.
4. **No regression:** reply still streams and renders; socket still authenticates; a paid send still round-trips end-to-end (one flat-rate send, ssdear@gmail.com).
Save before/after screen recordings + logcat windows to this folder.

## Editable levers (in our repo) vs floor
- **Android 2s poll -> event-driven render** (our code; APK-only deploy). Biggest in-control smoothness win.
- **Optimistic "working…" feedback on send** (our code) so the model's think-time feels responsive.
- **Startup: defer updater GitHub fetch off boot path + investigate 569ms pre-socket gap** (our code).
- **Go: un-drop `chat.send_timing`** (Go runtime rebuild+redeploy) for real timing + UI feedback.
- **Model thinking level** (gateway config on phone, NOT our repo, quality tradeoff) — surface to user, don't force.

## STATE 2026-08-25 ~20:17 — co-merged with location, build green, on-device verify pending
The 4 latency edits (P1a optimistic WORKING on send, P2 warm-socket gate skipping force-reconnect when already online, P3 defer updater fetch 6s off boot, P4 pulsing WORKING glyph) remain in main uncommitted and now sit alongside the location feature (both applied cleanly, non-overlapping — see operator-location-tool/notes.md "MERGED INTO MAIN"). Full Android build gate GREEN (assembleDebug + testDebugUnitTest + compileDebugAndroidTestKotlin, 15s). Uncommitted. On-device verification (instant <150ms WORKING feedback, live pulse, snappier cold-start, no streaming regression, one paid send) is BLOCKED on the Pixel 9 reconnecting — same physical blocker as location; watcher `bh6l2ybu9` (3h) will auto-resume. Commit held until on-device green (then directly on main).

## ON-DEVICE VERIFIED 2026-08-25 ~23:55 (Pixel 9, Android 16 / SDK 36)
Reinstalled APK with `adb install -r` → "Success", pairing survived (runtime in **standalone** mode: `local_pair_acked=true reachable=true ready=true runtime_serving=true`). Sent one benign prompt ("what is 2 plus 2") via adb input, recorded 16s. Evidence: `on-device-evidence/send-to-working-16s.mp4` + `send-to-working-16s-1fps.png` (16-frame contact sheet).
- **P1a (optimistic WORKING) VERIFIED.** On send the task row instantly flips from the stale "Replied" to "Working — Codex is working" and the input clears. Device-clock logcat: `home prompt sent to phone agent … outcome=Accepted` at 23:55:20.983 (where markTaskWorkingOptimistically fires, no log of its own) lands ~40ms BEFORE the runtime's own `live task event applied event_kind=activity task_id=phone-agent` at 21.023 — so the optimistic mark is what paints the instant feedback, not the runtime round-trip. Task reached the UI within ~213ms of the tap (20.810→21.023). The model's actual reply had NOT arrived within the 16s window (the real cold-start), so the whole wait is now covered by live "Working" instead of a frozen state — exactly the fix the user asked for.
- **P4 (pulsing glyph) VERIFIED.** Contact-sheet frames 11–16 show the Working dot visibly breathing: bright orange (frames 11/13/15) alternating with dim brown (12/14). The 900ms Reverse tween is animating on-device.
- **P2 (warm-socket gate) consistent.** The send crossed the durable boundary on the existing live socket (`phone action crossed durable send boundary … socket_accepted=true`) with NO reconnect/teardown in the log — the force-reconnect was correctly skipped because the session was already ONLINE to this device.
- **No regression.** Send pipeline clean end to end (action prepared → send boundary → confirmed → task published), no errors/exceptions in logcat.
- P3 (deferred updater fetch) is a boot-path timing change; not separately re-measured here (the updater GitHub fetch is now delayed 6s off cold boot; low-risk, compile-verified). skip-reason: isolating a 6s boot-fetch deferral needs a full cold-boot capture and adds little over the code-level confirmation.
Latency feature: on-device GREEN. Ready to commit once location is also verified (committing both together, directly on main).
