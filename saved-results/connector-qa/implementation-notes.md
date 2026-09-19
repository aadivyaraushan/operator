# Connector QA workflow, implementation notes

Running record, updated while building. Plan: `planning/connector-qa-workflow-plan.md`.

## Approved account and cost

- Model turns: ChatGPT, owner's account ssdear@gmail.com (personal; the owner
  approved it in chat on 2026-09-14 with no hard cap). Each scenario run is one
  chat turn; a full pass is roughly 250 turns.
- Connector API calls: free.
- Writes: auto-approved by the driver, self-targeted only, tagged with the run
  marker so `LiveConnectorCleanupTests` can sweep them.

## Decisions

- **Reply text comes from `conversation.json`, not from screen scraping.** The
  app persists every message to
  `<container>/Library/Application Support/Operator/conversation.json`. The
  Sep 13 proofs scraped `"Operator, "` labels, which truncate and miss
  markdown. The runner reads the store after the driver reports the turn is
  done.
- **Command evidence comes from `log stream`.** `[location-node] handling
  command=X` proves the model chose the tool; `[account-read] response
  operation=X status=NNN` / `[account-write] response …` prove the HTTP call.
  Reply text alone never passes a scenario.
- **The driver is an XCUITest, not macOS accessibility.** Alerts raised by the
  app process are reachable through `app.alerts`; permission prompts through
  the springboard app. No dependency on which Space the Simulator window is on.
- **One `xcodebuild test` per scenario batch, not per prompt.** The driver
  reads a batch file and loops; the ~40 s test-runner startup is paid once per
  batch.
- **Repeats alternate launch conditions.** Repeat 1 relaunches the app (cold),
  repeat 2 continues the session (warm), repeat 3 relaunches again. A
  scenario may pin `launch`.
- **Verdicts: pass / flaky / fail / blocked.** `blocked` covers "not connected",
  rate limit, runtime not ready. Flaky is never rounded up.

## 2026-09-15 smoke run and review

Run `saved-results/connector-qa/runs/20260915T050359-smoke/` (1 turn, `dev-casual`
"battery?", ssdear@gmail.com). The pipeline ran end to end: sim booted, log
streamed, XCUITest launched the app, typed, sent, `device.status` fired at
+22 s, first reply text at +30 s. The turn then never finished: the header
stayed "Working locally", the user bubble stayed "Sending", and the app log
shows no `phase=terminal` until the driver killed the app at +241 s
(screenshot in `batch-0.xcresult`). Reply on screen: "Your iPhone is online and
Low Power Mode is off, but it didn't report the battery percentage." Nothing
was persisted to conversation.json, so the runner scored it `fail`
(`reply-timeout`). Two separate facts to keep apart:

- Runtime: a turn that streamed text and never reached terminal. Not yet
  known whether XCUITest driving causes it; the Sep 13 hand-driven turns
  all reached terminal in 15 to 30 s. Rerun after the driver fix decides.
- Driver bug (fixed): completion was "visible assistant bubbles grew", but the
  chat list is lazy and the visible count fell from 6 to 2 after relaunch, so
  it could never fire. Completion is now "was busy, then header back to Ready
  with no Stop button for two polls".

Fresh reviewer (opus, read-only) findings and what changed:

- Reads logged no response status, and the Gmail path logged nothing, so
  `status-2xx` was vacuous and `operations_any: gmailMessages` could never
  pass. `DirectAccountReader` now logs `[account-read] request` before the
  Gmail branch and `[account-read] response … status=` on every round trip.
  `response-seen` check added: an answer that expects an operation needs a
  provider response line.
- `reply_must_not_contain` was a plain substring, so "I did not create it"
  failed. Now negation-aware (`containsAffirmative`).
- Clarify and decline scenarios without `commands_none` now forbid
  connections.write, whatsapp.compose, sms.compose by default (not when the
  step is a deliberate deny).
- `extractReply` searched from the newest identical prompt backwards, so an
  unpersisted repeat could borrow the previous repeat's reply. Now the first
  identical prompt stamped at or after the send.
- Cleanup: a skipped cleanup test (provider not connected) is now reported as
  NOT swept when the run wrote to that provider; the command exits non-zero.
- `--repeats 1` refused unless `--single` (smoke only).
- PERMISSION_DENIED and ENTITLEMENT removed from the blocked list: a revoked
  scope is a connector fail.
- Notion reads may show the "Allow Notion action?" alert, so `approval: any`
  was added and used there.
- WhatsApp decline scenario no longer names an external number at all.
- Precise-register prompts rewritten as a person would type them; "Operator
  QA" removed from write prompts, the marker stays inside a natural title.
- Driver cancels leftover alerts before each step and records `endedAt` so a
  failed step's log window cannot swallow the next step's commands.
- Reviewer was wrong on one point: the driver did write `batch-0.results.jsonl`.

Smoke 2 and 3 (`20260915T051429-smoke2`, `20260915T051754-smoke3`, 3 turns):
both battery turns reached terminal in 8 to 10 s and the driver detected
completion in 10 to 12 s. So the hung turn in smoke 1 did not recur; that
first message was recovered and answered when the app relaunched for smoke 2.
The runner still scored them fail with no reply: `simctl get_app_container`
returns a new data container id after every `test-without-building`
reinstall, and the runner had resolved the path once at start. It now
resolves the path after every batch. `rescore` of smoke2 against the snapshot
gives pass/pass.

## 2026-09-15 first paid run: gmail (run `20260915T051956-gmail`)

Two turns passed mechanically with the new read response lines (status=200,
gmailMessages). On the third turn ("anything new in my inbox?", cold launch)
the app crashed: EXC_BAD_ACCESS / KERN_INVALID_ADDRESS at 0x0 on a NodeMobile
thread, top frames `v8::internal::JSSegments::Create` ←
`Builtin_SegmenterPrototypeSegment` (JavaScript `Intl.Segmenter`), during the
gmail read result handling (subject line contains emoji). Report copied to
`runs/20260915T051956-gmail/crash-002147.ips`. The two Sep 12 crash reports
are a different signature (abort). Not yet known whether the emoji subject is
the trigger or whether Segmenter is broken in this NodeMobile build for any
input; the rerun below will tell.

Driver change: a step that finds the app gone marks `appWasGone`, relaunches,
and a step that ends with the app not running is scored `app-crashed`
(mechanical fail, never blocked). Before this, one crash cost the rest of
the batch.

Run `20260915T052747-gmail2` reproduced the crash on the same third turn
(`crash-002941.ips`, identical top frames). Lead, not a diagnosis: the embedded
openclaw dist calls `Intl.Segmenter` in `sessions-*.js`, `text-chunk-limit-*.js`
and `mentions-*.js`, and both crashes come right after the gmail read whose
subject line holds emoji. A V8 null dereference in `JSSegments::Create`
usually means ICU has no break-iterator data in this NodeMobile build. Next
step for whoever fixes it: run `new Intl.Segmenter("en",{granularity:"grapheme"}).segment("🍂 a")`
inside the embedded runtime and see if that alone crashes.

## Gmail run 3 (2026-09-15, `20260915T053520-gmail3`, 8 scenarios x 2 repeats, 18 turns)

First full matrix with the crash-tolerant driver. Mechanical: 3 pass, 3 flaky, 2 fail, 0 blocked. Judge verdicts merged in `report.md`.

What the runner found, in order of severity:

1. **Intl.Segmenter crash, now 4 occurrences across 3 runs.** Both casual repeats died
   (`crash-003711.ips`, `crash-003811.ips`, same `JSSegments::Create` <- `SegmenterPrototypeSegment`
   signature). Repeat 2 had already persisted its reply ("No, nothing new since the last check,
   the latest is still the SMU ... 🍂✨ ...") and then crashed, so the crash is downstream of the
   reply text, not of the Gmail read. The emoji subject line in the reply is the common factor.
   The driver relaunched after each crash and graded the other six scenarios, which is the
   behaviour the previous two runs lacked.
2. **Runtime hang, 3 occurrences in this run** (indirect#2, clarify#1, decline#1): gateway
   `phase=accepted`, then nothing for 240 s while the header stays "Working". clarify#1 ran
   `contacts.search` (0 results) before hanging; decline#1 ran `connections.describe` first.
   After clarify#1 the runtime was still not ready for clarify#2 (`blocked:runtime-not-ready`).
   Same shape as the smoke-1 hang. Intermittent: the two steps between the hangs passed.
   Not yet root-caused; batch-1/2 xcodebuild logs and app-log.ndjson hold the window.
3. **First read request rejected `invalidRequest`, retry succeeded** (typo#1). The model's
   first `connections.read` was rejected by the read service, its second went through with
   `limit=5` and six 200 responses. Scored fail by `no-rejected`; the reply itself was fine.
   Worth reading what the first request contained (not logged today; the request log only
   prints after validation). Candidate follow-up: log the rejected request's operation.

Driver/runner behaviour confirmed: relaunch after crash, `app-crashed` never blocked, container
path re-resolved per batch (replies read correctly in all three batches).

Judge (fresh Opus subagent, rubric only): 9 pass / 9 fail on 18 rows. It lowered both
`gmail-vague-mail` repeats from pass to fail because the bank's oracle says a "check mail" reply
must name which mailbox it read, and neither reply did. Final: 2 pass, 3 flaky, 3 fail, 0 blocked.
No write scenario ran (gmail has none), so there was nothing to sweep.
