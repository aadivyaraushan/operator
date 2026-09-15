# iPhone connectors — evidence

## Full LLM-path proofs for every write + Notion, cleanup green — September 13

**What this proves:** not just "the connector code can call the API" but the
whole product path a user hits: type a natural-language prompt in the app →
the LLM (ChatGPT, owner's account ssdear@gmail.com, pre-approved) picks the
connector tool and fills its parameters → the app shows the "Allow account
action?" alert → owner taps Allow → real API call → reply lands in chat.

Log signature for each proof (`log stream --level info`, subsystem
`app.operator.ios`): `[chat] staged input` → `[account-write] input
operation=X` → `request` → `response operation=X status=2xx` → `complete` →
`[chat] reply persisted`. The `input` line only logs **after** Allow, so it is
proof the alert was accepted, not just shown.

| Operation | pid | `response … status` | time (Sep 13) |
|---|---|---|---|
| googleCalendarCreateEvent | 14137 | 200 | 19:42:01 |
| outlookCreateDraft | 14502 | 201 | 19:43:00 |
| outlookSendMail (to ssdear@gmail.com) | 14779 | 202 | 19:44:00 |
| slackPostMessage (channel D0BK8RHK6KW, own DM) | 17926 | 200 | 19:56:05 |
| googleDriveCreateTextFile | 69414 | 200 | Sep 12 23:20:02 |
| Notion read: `notion.tools` → `notion.call` notion-fetch(self) → notion-search("Operator Live") | 20043 | reply "History project / bb2fff87-…" on screen | 20:02:01 |
| Notion write: notion-create-pages (draft) → notion-fetch verify | 20487 | reply "Page ID 3db27879-aaa0-81d0-b83b-e57d03cbebca, exact line present: Yes" | 20:03:50 |

Notion has no `[account-write]` lines (it goes through `ForegroundNotionService`,
which logs only `handling command=notion.call`); the proof there is the on-screen
reply carrying real workspace data plus the alert screenshots taken before each
Allow (tool name and arguments visible: `notion-fetch {"id":"self"}`,
`notion-search {"query":"Operator Live","page_size":1}`,
`notion-create-pages {...}`).

All 10 reads were proven via the LLM path on Sep 12 (see below).

**Not done via LLM path:** `spotifyStartPlayback` — needs an active Spotify
Premium device (owner must open Spotify and press play/pause first); playback
would be audible. Direct-API proof exists from Sep 12.

**Cleanup (green, 20:04):** `LiveConnectorCleanupTests` (OperatorAppLive scheme,
live sim, scratch derivedData) deleted every `operatore2e0912` artifact:
`google driveFiles=1 calendarEvents=1`, `outlook messages=2` (draft + sent),
`slack messages=1`. Left behind on purpose: the Notion draft page
`Operator Live Test Fixture - safe to delete` (`3db27879-…`) — the connector has
no delete/archive tool; owner deletes it by hand.

**Driving recipe that finally worked** (for reproducing): `inject.sh "<prompt>"`
sets the conversation draft and relaunches; then computer-use `app_click` on
`AXButton "Send"`, wait for the alert (for writes ~15 s; for Notion, wait for
`handling command=notion.call` in the log — there is one alert per tool call),
`app_click` on `AXButton "Allow"` — the result must say `AXPress`. A "raw input"
result also worked once the window was on the current Space.

**Lessons / gotchas (cost several hours):**
1. **Never pass `CODE_SIGNING_ALLOWED=NO` when building for the live sim.** It
   installs an unentitled binary that cannot read the data-protection keychain →
   `KeychainStoreError` for every provider, Notion `state=failed`, runtime gate
   closed. Tokens were not lost; a normal signed rebuild + `simctl install`
   (upgrade, not uninstall) restored everything. That flag is only for the
   throwaway sim.
2. Simulator window on a full-screen / other Space: Send still works via AX
   click-through but the alert's Allow does not — every write timed out (30 s
   cap in `ForegroundAccountWriteConfirmationService`). Fix: keep the Simulator
   on the current, non-full-screen Space.
3. Waiting on `[account-write] input` before tapping Allow is a deadlock — that
   line logs after Allow. Poll the screen instead.
4. `log stream` needs `--level info` or the `[chat]` lines never appear.
5. The Notion fixture page id from Sep 12 (`3dae6004-…`) now returns 404 —
   the owner reconnected Notion (token had expired overnight) and the page is
   not reachable from the current connection. The live test self-heals by
   creating a new draft; the LLM run did the same.

**Product gaps surfaced (not test-setup problems):**
- LLM cannot discover the owner's own Slack DM channel id; it guessed one and
  got `INVALID_REQUEST` (`rejected branch=typed-validation`). Works once the id
  is in the prompt. Needs a "my DM" lookup in `connections.describe`/read.
- Every Notion tool call prompts — including reads and even fetching the
  markdown spec — so "create a page" = 3 alerts. Reads should not prompt.
- 30 s alert timeout is tight when the owner is not staring at the phone.
- Notion connector has no delete/archive tool, so writes are not fully
  reversible.

**Cost:** ~14 ChatGPT chat turns today on ssdear@gmail.com (pre-approved).
Connector API calls are free.

## Unavailable-action checks — September 11, 19:14

Separate website retry opened19:15:18.223, reply completed19:15:22.331 (21.215s), remains visible. Escape key accepted but did not dismiss; invalid ESC spelling produced keyNotFound with no input. Manual Done check requested via async question. Read SystemAppHandoffOpener.swift and InAppMediaOpener.swift: normal Safari presentation. Apple docs safariViewControllerDidFinish state the view is dismissed afterwards; no confirmed missing-dismiss bug and no patch. Do not substitute app restart for manual return. CLI tap exists but requires exposed elementRef, no raw-coordinate route.

Live read-only error checks completed13.182s. Deliberately nonexistent operator-test.invalid returned getaddrinfo ENOTFOUND; apps.open with unknown ID operator-test-unavailable returned APP_UNAVAILABLE: This app has no supported website hand-off. Native log19:14:09.676 confirms rejected unavailable destination; UI displayed both errors, did not claim success. No app/website opened for these error checks. Screenshot saved-results/ios-connectors-setup/screens/unavailable-actions-verified.jpg. A separate supported Starbucks opening/return check follows; do not confuse it with an alternative attempted by the error-check request.

Installed XcodeBuildMCP CLI does expose UI automation commands even though MCP tap is absent. Its tap still requires a visible tappable elementRef; it is not a raw-coordinate workaround for the absent Safari Done target. Investigating keyboard dismissal once rather than repeating failed coordinate taps.

## Real search completion verified — September 11, 19:12

Combined build PASS18.3s (build_sim_2026-09-12T00-10-56-191Z_pid3078_901fc7e2.log), signature/install/launch PASS. PID97958, data container F4F0DF6D-1EF7-4439-A5BA-426EDECB6A14. Private backup /private/tmp/operator-diagnostics-install.WDRd9v. Saved150 messages/draft/config match exactly after install.

Read-only Yellowstone web search: upstream /private/tmp/openclaw/openclaw-2026-09-11.log lines8578-8579 records provider completion at19:12:26.174/.180, same trace402ddd49ff61bd84ad53f7f79be73589 from installed runtime. These are two notifications, not a two-search count. UI linked official NPS Plan Your Visit result; terminal19:12:28.341,elapsed19969.338ms. Screenshot saved-results/ios-connectors-setup/screens/search-completion-verified.jpg. After reply152 messages, prior150 unchanged,draft unchanged,outbox0. Search provenance now PASS.

Notion diagnostic code and tests included: success logs only after save; failures use fixed categories. Full Notion suite19/19 root-confirmed (/private/tmp/operator-notion-renewal-green.log); native40/40. No live renewal event yet. Current OSLog app.operator.ios_oslog_2026-09-12T00-11-44-108Z_helperpid97983_ownerpid3078_82e8f378.log. Preserve natural-expiry and website-return gaps, Weather owner deferral. No new external writes/auth/reset actions.

## Search completion diagnostic implementation — September 11

Root cause confirmed: direct ChatGPT transport has its own mapCodexEvents used by both SSE and WebSocket; generic observeResponsesStream diagnostics never run in this path. Added strict, repeatable package patch in compat/search/diagnostics.mjs. It logs only a fixed completion message for provider web-search completion event or completed web_search_call output item, using existing AI transport logger. No event data included. Multiple notifications can produce duplicate lines, so do not interpret line count as number of distinct searches.

Tests: actual unpatched handler RED 0 logs versus2 required; missing-module setup failure was corrected with identity stub before this true reproduction. Packaging RED missing marker. GREEN focused3/3; full native40/40 exit0 (/private/tmp/operator-search-diagnostics-green.log). StageRuntime passed, source preserved, generated prior runtime retained runtime-before-search-diagnostics-20260911. New diagnostics test executes extracted actual event mapper, checks identical forwarding, no private strings, only successful search completion and repeat/source-drift behavior. No live proof yet for this diagnostic until new build installed.

## Remaining verification boundaries — September 11, 19:08

Read-only renewal investigation: foreground/launch triggers saved checks in OperatorApp.swift:214-219. Slack accessToken refreshes only at expiresAt <= now+60 seconds (PhoneOAuthClient.swift:123-150); exact proof is phone-oauth token refreshed provider=slack plus a successful saved check/read. Notion validAccessToken refreshes only after expiry (NotionMCPClient.swift:158); performRefresh saves the replacement token at line128 but emits no refresh-success diagnostic. Existing connected status is not proof of renewal. No expiry tampering, reauthorization, credential dump or refresh-token manipulation performed. Natural expiry is required through the existing UI routes; Notion additionally lacks an exact success signal.

Search diagnostics investigation: actual running PID92581 contains SSE=off and payload=off (checked booleans only). The real upstream log /private/tmp/openclaw/openclaw-2026-09-11.log is actively written, but the diagnostic test period has gateway/memory/agent records and no transport stream_done or search event. Thus missing capture was not simply a missing log file. Bundled response decoder does not persist hosted web-search output items in the normal chat transcript. No stronger live search claim added. Logger host setup is imported by stream-BbY-2nPo.js and runtime host preserves the existing host fields; no confirmed initialization defect or code fix inferred.

## Search update installed and replies received — September 11, 19:04

Website was not an authorization flow. Left its Done-return test unverified, preserved state in /private/tmp/operator-search-install.3kzCtH and installed tested update without uninstall/reset. New data container 64588931-1961-4346-B809-62F9F55E463A. Verified exact preservation of all 146 prior messages, draft, outbox and config except native search defaults.

Public NASA search request: live linked NASA Artemis reply, terminal 19:01:45.588, elapsed 18238.677ms. Public NOAA search request: live linked Hurricane Preparedness reply, terminal 19:03:54.408, elapsed 24627.305ms. Both read-only, no provider setup or external changes. Screenshot saved-results/ios-connectors-setup/screens/search-reply-native.jpg. Search execution itself not proven: no search call persisted in transcript, and OPENCLAW_DEBUG_SSE=events (payload off) produced no matching captured search-event counts. No new instrumentation patch. Restored diagnostic off and reopened PID92581. Latest runtime/OS logs suffix 2026-09-12T00-04-27-560Z_helperpid92577_ownerpid3078_5469fa52.log and 2026-09-12T00-04-28-387Z_helperpid92605_ownerpid3078_8347c4ca.log under existing XcodeBuildMCP logs directory.

After final reopen: 150 messages, previous146 prefix exactly unchanged, original draft unchanged, outbox0. Still need search provenance and remaining live refresh/return checks. No owner Done action required now; that original check remains SKIP, not replaced by restart success.

## Native search configuration — September 11

Update 19:00: packaging returned NATIVE_RUNTIME_PACKAGE_PASS (exit 0), generated state.mjs matches source. Prior runtime preserved at ios/build/native-node/runtime-before-search-20260911. Actual bundled module import passed 5 checks with synthetic auth: native activation, live payload, missing setting rejection, ineligible model rejection, missing-auth rejection. No provider request. Build first failed on duplicate derivedDataPath, then passed in 16.7s after setting it through nonpersistent XcodeBuildMCP session defaults. Successful build log: /Users/aadivyar/Library/Developer/XcodeBuildMCP/workspaces/codex-launcher-d2717d016e42/logs/build_sim_2026-09-11T23-59-34-052Z_pid3078_2cde8f37.log. Fresh screenshot still shows Starbucks; no install or restart while waiting for the Done return check.

Implemented missing `tools.web.search.openaiCodex` defaults (`enabled: true`, `mode: live`) in native `gateway/state.mjs` creation and migration. Preserves explicit provider/disable/mode/restrictions and all unrelated fields. No Codex executable, separate key, account edits or installation in this step. Current upstream web docs and exact bundled direct ChatGPT Responses activation/payload inspected; the newest docs also describe app-server paths that we are not adopting.

Test-first: `node --test ios/Runtime/native-node/tests/state/state.test.mjs ios/Runtime/native-node/tests/state/bootstrap.test.mjs` failed 4 of 10 before implementation (missing settings), then passed 10/10. Full native suite (package/stage, compat/sqlite/ownership, compat/lifecycle/export, host/start, compat/recovery/source-run, state/state, state/bootstrap): 38/38, exit 0. `git diff --check` passed. Production initializer search found creation and migration only, both covered. Live search/provider acceptance and new build/install remain unverified. Saved credentials and chat in the Simulator were not modified by these tests.

After the owner reported Done, a fresh CUA screenshot still showed the Starbucks website and top-left Done. Requested another tap; did not relaunch or dismiss cookies. Website-return check remains open, not a verified pass.

## Website reply completes; return pending owner tap — September 11, 18:50

Fresh connection-sheet check: Google/Outlook/Slack/SpotifyConnected, YouTubeKey saved. No provider reauthorization or expiry manipulation. Current logs did not show a new token-refresh event; do not infer one from Connected.

Official Starbucks website opened18:50:20.926, native actionCompletedfalse/draftTransferredfalse. Chat terminal reply18:50:23.561,total14.249s. Saved146messages,outbox0,originaldraft preserved, latestassistant record mentionsStarbucks. Website screenshot shows Done and cookie overlay; no cookie consent or other site action taken. CUA Done coordinateclick failed noWindowsAvailable. No tap capability in exposed XcodeBuildMCP tools. Owner asked to tapDone; no relaunch to fake a return check. Screenshot saved-results/ios-connectors-setup/screens/website-return-pending.jpg. Current app PID80984, logs same as preceding Slack/recovery checks.

Standalone renewal-related tests rerun: auth22/22 exit0, Notion15/15 exit0. /private/tmp/operator-remaining-auth-auth.log and /private/tmp/operator-remaining-auth-notion.log. These use synthetic transports; do not prove Slack/Notion real renewal. No new source/config changes. Still need live general internet search distinct from successful fetch, remaining renewal evidence and permission-interruption coverage. Weather remains owner-deferred. Goal active, not complete.

## Slack channel pagination and history passed — September 11, 18:48

Fresh bounded prompt followed returned cursor for at most5pages until channel available, never joining/sending/marking read. Native log PID80984 shows slackChannels limit1 at18:47:38.303 and18:47:44.469, slackHistory limit1 at18:47:50.475; terminal18:47:53.870,total29.212s. UI: Pageschecked2, ChannelsSuccess1, MessagesSuccess1. Draft preserved. Screenshot saved-results/ios-connectors-setup/screens/slack-history-live-success.jpg.

Earlier history SKIP replaced by real read PASS. First page0 was not exhausted channel discovery; pagination found a channel. No names/IDs/content exposed in result, no account changes. Does not prove arbitrary message ranges or token refresh. Next reliability gaps: provider refresh evidence, permission interruption, app opening/return and accurate unavailable/empty-page interpretation. Weather remains explicitly owner-deferred; no full goal completion.

## Interrupted ordinary read recovered live — September 11, 18:46

Two corrections installed: exact native iOS admission allowed by local pinned gate with other guards unchanged; per-message fastMode removed and equivalent supported default added to valid JSON settings only when absent. Explicit settings/auth/model preserved. Tests: gate/stage12/12; final native36/36, chat37/37, core82/82 (77.834s); wire RED12tests1failure then GREEN12/12, default RED7tests2failures then GREEN7/7. Bootstrap strict observed config compares all saved fields plus intentional default. No global browser predicate changes. Build20.8s /private/tmp/operator-ios-admission-build.log. Signature, install, launch passed. Backup /private/tmp/operator-ios-admission.EWcvhO.

Before fresh test140messages/draft identical; auth/model unchanged, fastModeDefault auto. Sent one read-only example.com fetch source36ada966-5ce4-49b9-bdea-392402bb2386, restored draft, Home during work;141messages,outbox1. Coldreopen PID80984. Native pending recognized18:46:05.994,07.097,08.223, retaining request. Exact saved reply recovered18:46:09.322, UI success. No chat.send in reopen log. Transcript seq366 assistant stop run7738e102-2c53-4bc5-bdbd-a8c3d0da8d4e has sourceRunId36ada966-5ce4-49b9-bdea-392402bb2386. Final142messages,outbox0, entire140message prefix and draft preserved. Screenshot saved-results/ios-connectors-setup/screens/recovery-live-success.jpg.

Logs XcodeBuildMCP codex-launcher-d2717d016e42: app.operator.ios_2026-09-11T23-45-57-334Z_helperpid80981_ownerpid3078_98280b89.log and app.operator.ios_oslog_2026-09-11T23-45-58-180Z_helperpid81041_ownerpid3078_61b349be.log. Data container004BAFD6-4FE8-433F-9602-2032F0201D87. This replaces the earlier interrupted ordinary-read FAIL with PASS for this scenario only. Does not prove external writes, playback, attachments or permission interruption. Slack history/refresh and other remaining coverage still open; Weather owner-deferred.

## Root cause of absent native recovery identity — September 11

Confirmed by root source inspection and read-only helper database evidence. GatewayWire.swift:190,201 uses openclaw-ios. message-channel-BGKf9KPa.js:28-30 browser predicate excludes iOS. chat-send-handler-DBjXcn_1.js:3771-3777 makes restartSafeRequest eligible only for that browser predicate plus additional safety conditions. Native iOS never creates that request. Without admission, buildRestartSafeChatTranscriptState is not spread at4488-4494. Thus source ingress/run fields are absent before generic recovery. Current DB terminal entry has ingress/source/recovery NULL; transcript recovered assistant has runId but no sourceRunId.

Installed attachment implementation and helper are correct copies; SHA matches, ruling out stale bundle/different attachment function. The previous control-ui-only producer cannot work without durable native admission. Next correction belongs at the exact local packaging eligibility gate, explicitly adding iOS while preserving all remaining safety predicates and other client exclusions. Test actual predicate first, then implement and live-retest. No source-order heuristic, browser impersonation, credential reset, or unapproved external action.

## Validated install, live recovery still fails — September 11, 18:39

Strict repeat-patch regression RED8/10 then GREEN10/10; full native suite34/34 exit0 (/private/tmp/operator-native-full-green.log). Public recovery fixtures restored in the local ignored original-package directory; tests no longer rely on a sibling worktree. Build15.6s, signature/install/launch passed. Installed helper SHA2569ab3685d8eb4bbbccaa3dee57686d9128f5640df70bf9ed54b5a9bc4e6c5470f matches staging.

139messages and draft matched backup exactly before test. Read-only example.com source run eeb38a80-7028-4097-afee-80beeb0f2ae7; Home while working; draft preserved, outbox1. Cold relaunch PID75819. History foundfalse18:39:08.815 and18:39:09.094 then original request failed. Native recovery completed18:39:12 as5659e092-b3dd-4a63-98ab-09a1f35037f7. Transcript seq358 assistant stop has that runId but NOsourceRunId. UI says no readable result received; completion not verified. Live recovery remains FAIL. Installed producer/projection did not cover actual path; diagnosis only underway, no guessed follow-up.

Container A8AEA214-3A88-4B2F-88CC-F4232186D275. Runtime log app.operator.ios_2026-09-11T23-38-59-529Z_helperpid75815_ownerpid3078_c6e8a0cb.log; OSlog app.operator.ios_oslog_2026-09-11T23-39-00-380Z_helperpid75887_ownerpid3078_9e510cda.log, both under XcodeBuildMCP codex-launcher-d2717d016e42 logs. No credentials or private message content exposed. All connector scope and owner-deferred Weather unchanged.

## Recovery package and build checks — September 11

- Full core log /private/tmp/operator-recovery-core-full.log: 82 tests, zero failures, 77.880 seconds.
- Native recovery and stage tests: 10/10 before packaging. Staging returned NATIVE_RUNTIME_PACKAGE_PASS. Three changed generated modules passed node --check.
- Build log /private/tmp/operator-source-recovery-build.log: OperatorApp Simulator Debug build succeeded in 18.7 seconds.
- Wider native tests: 21 passed, 3 failed. Two files depended on missing public upstream inputs. Restored only run-CrJnbDWP.js, openclaw-state-db-Bh3Bq87y.js and openclaw-state-db-readonly-C7txILW9.js from the original ios-operator public package into ignored ios/build/runtime-recovery/openclaw-source/package/dist. SQLite/lifecycle tests then passed 11/11. No test assertions changed for those two failures.
- Remaining native test failure: repeated recovery patch shortcut missed source drift after staging, under repair. New build not installed yet.
- Existing runtime preserved at ios/build/native-node/runtime-before-recovery-source-20260911. Conversation backed up privately at /private/tmp/operator-source-recovery.cZ9BFl/conversation-before.json; no credentials printed or reset.
- Live interrupted-work recovery is still unverified for this fix. Weather remains deferred by owner. Slack message reading is skipped, not passed: no channel returned.

## Explicit recovery identity and pending-state handling — September 11, 18:32

Added sourceRunId recovery fixture: RED12tests1failure, GREEN12/12. GatewayWire now accepts only an explicit sourceRunId attached to a message that also has runId, retaining role/completed-result checks; later unrelated messages cannot substitute.

Added integration scenario for exact native recovery pending both before send and after early failure: RED37tests5assertion failures in the new test; GREEN37/37 after implementation. GatewayChatHistoryResult now decodes optional operatorRecovery {sourceRunId,runId}. OpenClawGatewayConnection.recoverReply first returns a matching completed reply, otherwise throws recoveryPending only for an exact source match and nonempty recovery ID. LocalOpenClawChatGateway reconciles history after a failed event before clearing the request, and maps pending to "Operator is restoring this request." Existing catch/reconnect flow retains and retries the same saved request. No generalized retry of arbitrary errors was added.

Native producer/packaging compatibility work is in progress with the implementation helper; not installed yet. Full core suite launched separately and pending at this entry. Existing latest installed app remainsPID65078, with the known interrupted-read failure and later successful connector checks. No new live recovery claim. git diff --check passed.

## Notion page and WhatsApp message reads verified; Slack history skipped — September 11, 18:27

On installedPID65078, bounded read-only grouped check completed in70.203s including two Notion action confirmations; first text69.090s. Native Slack request was slackChannels limit1 at18:26:16.018. UI channels0; no Slack message-history invocation in account-read log, so history SKIPPED because no channel was available. Model final incorrectly labeled Slack messages Success0items; that is not test evidence and accurate skipped-state wording remains an issue.

Notion search queryOperator page_size1 and notion-fetch for its result were explicitly inspected and allowed in the existing app confirmation UI; these were the already-authorized bounded reads, not new permissions or writes. UI returned search1/page read1; node logs show notion.call requests18:26:33.367 and18:26:47.873. No page text/identifiers included in final.

Native WhatsApp chats limit1 completedcount1 at18:26:16.247, messages limit1 completedcount0 at18:26:27.244; UI agrees. These are actual local read queries, not a fresh server sync (earlier sync21 is separate). Draft remains exactly Resume check — keep this draft unsent. No sends, mark-read, edits, creation or playback. Restart mapping investigation continues independently with a read-only source helper; no additional code edits this turn.

## Live in-progress interruption still fails — September 11, 18:24

Sent one read-only example.com fetch18:22:37.959; restored original draft. Simulator Home AX did not visibly change screen, but super+shift+h did: screenshot/AX confirmed Home Screen and native foreground route stopped18:22:44.710. Conversation retained137messages, sending entry5c711392-c1e3-41d2-a954-8a819518c35e, original draft intact. Read-only transcript metadata before reopen showed user, toolUse and toolResult but no completed reply.

Tried stale Operator-widget AX element: invalid-element error, refreshed tree no longer contained it. No widget success claimed. Used XcodeBuildMCP launch to return; newPID65078 means this is a cold-relaunch test, not proof of same-process resume. Did not infer why previous process ended.

On relaunch exact-history found=false18:23:29.969, request accepted18:23:29.985, original run failed18:23:30.244. OpenClaw independently logged startup-orphaned recovery started1; its recovery run75de666c-9a05-4514-831b-808067a4b74a terminated statusok18:23:35, followed by another keyed-user-outside-current-turn error. UI returned Ready without a final reply to the test request; draft remains. Therefore in-progress interrupted-work recovery is NOT complete. Evidence suggests interaction between app retry and OpenClaw restart recovery, not yet a proven full causal chain. Source main-session-restart-recovery--2blnuu5.js creates a recovery run separate from its source run; inspect supported history/recovery status mapping before changing behavior. Do not disable upstream recovery, fabricate a reply, repeat external actions, or call goal complete.

## Queued request resumes; normal Drive and Spotify reads pass — September 11, 18:22

Corrected build10.6s passed and installedPID63705. Chat suite rerun36/36 exit0; history suite11/11 exit0. On reopen, the queued request passed exact-history decoding (found=false18:21:28.175) and was accepted without owner input18:21:28.305. Native account-read logs: googleDriveFiles limit1 at18:21:45.581; spotifyPlayback limit1 at18:21:46.016. UI final Google Drive Success0items, Spotify playback Success0items. Firsttext20.472s, terminal21.175s. Original draft visible unchanged. Prompt was ordinary-language, did not specify tool names, query fields or limit, and prohibited changes/private detail display. This proves usable Drive/Spotify credentials after install plus automatic queued-request recovery and required-parameter selection; not a token-expiry refresh or already-completed-run recovery. No explicit provider HTTP status captured in this check. No writes/playback. Full goal remains active.

## Recover-before-send implemented; live shape mismatch caught — September 11, 18:20

Full core run completed80/80 exit0 (77.85s). Added gateway integration regression requiring connect,chat.history only for an existing completed run: RED36tests2assertions failed, GREEN36/36 exit0 after LocalOpenClawChatGateway checks exact history before send. Existing fixtures now answer history before sends, and method-order assertions include it. Build succeeded11.2s, installedPID61865. All134 messages and original draft exactly preserved against /private/tmp/operator-recover-first.k0iMhr/conversation-before.json; outbox0 before new check.

Sent a read-only ordinary-language Drive/Spotify check, restoring the original draft. Live history decode failed immediately, so message remained queued. Stopped app to halt retry loop, without deleting queue or credentials. SQLite type-only inspection:48 user messages have string content;135 assistant and88 tool-result messages have array content. Added plain-text history regression: RED11tests1failure at messages[0].content expected array/found string; GREEN11/11 after decoder accepts both text and block arrays. Reconnect rerun and rebuild pending at this entry. Original pre-send recovery test remains fixture-proven, not live completion-proven. No external write, playback, website action repeat or purchase.

## Recovery diagnosis and native history reader fix — September 11, 18:15

The new-process OSLog confirms automatic retry at18:11:23.932, followed by run failure at18:11:24.871. Runtime log identifies "Session transcript keyed user is outside the current turn". Read-only SQLite metadata shows the original user at seq312, completed assistant stop at319, then retry error at321. Both assistant records use __openclaw.runId, whereas the old GatewayWire recovery selector checked only idempotencyKey. No message content, credentials or database state was modified during this inspection.

Added testHistoryRecoveryReadsNativeRunIDAndSkipsToolStepsAndErrors to the existing GatewayEventReducerTests: RED 10 tests/1 failure (selected Other reply instead of Website opened). Changed GatewayWire to decode runId and stopReason, prefer native runId over the legacy key, and reject explicit non-stop results. GREEN targeted suite in the full run:10/10. Full core run still in progress at this entry. No Simulator rebuild/install yet, so live recovery remains unverified. The separate send-before-history recovery behavior and nonpersistent failure display still need work. Source search found a single production exactAssistantReply selector and its gateway caller. Existing logging records exact recovery run/found; no new data logging needed.

## Return check after owner tapped Done — September 11, 18:11

After the owner reported tapping Done, the visible Simulator accessibility state showed Safari on starbucks.com. Home did not visibly return to Operator. Launching Operator through XcodeBuildMCP restored its chat screen (PID55438). Accessibility inspection confirmed Ready and the exact unsent draft. Saved conversation inspection found 134 messages, the draft preserved, and an empty outbox. The last saved message is the website-opening request with delivery accepted; there is no saved assistant reply after it. Therefore website opening and draft preservation pass, but automatic return and final reply recovery are not proven. Do not count the complete handoff flow as finished. No website action was repeated and no purchase, sign-in, or send was performed. One read-only inspection command had a syntax error; its corrected rerun exited 0 with these counts.

## Website handoff opened; return check awaiting owner — September 11, 17:40

apps.open test opened the listed official Starbucks website inside SFSafariViewController, verified by screenshot showing starbucks.com and native app-handoff log at17:39:51.190: website opened actionCompleted=false draftTransferred=false. Earlier unavailable destination at17:39:43.292 was followed by a successful retry at17:39:50.610; exact first argument not inspected, so case mismatch is not confirmed. No orders, login, cookies consent or site actions submitted. Original draft restored before opening. Returning to chat remains unverified: Safari Done is visible in screenshot but absent from AX, coordinate clicks twice failed noWindowsAvailable even after Raise, Escape had no effect. Asked owner to tap Done. No restart or invasive workaround. This proves website handoff, not native third-party app opening or task completion; overall goal incomplete.

## WhatsApp live server sync passed after reopening — September 11, 17:38

After app restart, requested one native whatsapp.sync with timeoutSeconds15, no sends/mark-read/settings/playback and counts only. PID33529 foreground-whatsapp at17:38:14.629 logged completed branch=sync count21; UI Status: completed — 21 messages stored. Firsttext28.819s/terminal29.104s including model time. This verifies the native server sync path beyond saved local chat access, with data stored locally; does not prove every message/history range or background synchronization. Draft restored and visible. Previous linking-error root cause remains unknown; successful later pairing/sync does not establish that error categories caused recovery. Remaining: app-opening, interrupted-work recovery, broader connector refresh and missing detailed read checks. Weather deferred to owner enrollment.

## WhatsApp local read survives reopening — September 11, 17:37

Idle reopen test completed: stopped PID26306 and launched PID33529 with XcodeBuildMCP. All129 preexisting messages and draft matched protected backup exactly after launch; outbox0. A new WhatsApp chat-list read limit1 through Operator returned Success1item, and original draft remains visible. Code inspection of native-whatsapp/read/read.go confirms this is a local database read gated by a persisted device record, not a fresh WhatsApp server connection. Therefore this proves local pairing data/history/draft preservation and usable chat reads after restart, not credential validity at the server or new-message sync. Backup /private/tmp/operator-reopen-proof.UUcmPd/conversation-before.json. No writes, sends or playback. Next checks: bounded sync, app-opening and interrupted work; other connector refresh remains only partially verified. Weather deferred.

## Public reads passed — September 11, 17:35

WhatsApp owner completed pairing. Fresh native chat-list read limited to1 returned count1 at17:34:00.177 (PID26306); app Success1item. Firsttext14.661s/terminal15.521s. New public reads: app Web fetch Success1page, Maps Success1result, Podcasts Success1result. Native Maps returned1 at17:34:46.848; podcast HTTP200 and result_count1 at17:34:47.033. Grouped read terminal24.518s. Draft restored; no sends, mark-read calls, playback, navigation, subscriptions or app opening requested. This proves basic WhatsApp linked local chat-list access, not ongoing sync, message reads or reopen persistence. Prior pairing failure is replaced by a successful basic read, but its earlier cause was not confirmed. App-opening, broader reopen/refresh/interrupted-work checks still remain; Weather remains deferred to owner Apple Developer enrollment.

## WhatsApp linked and live chat read passed — September 11, 17:34

Owner reported linked. Fresh read through Operator requested one native WhatsApp chat, with counts only and no sends/read receipts/mutations. foreground-whatsapp log PID26306 at17:34:00.177: completed branch=chats count=1. UI returned Success — 1 item and Ready. First text14.661s, terminal15.521s. Original draft restored and visible. This replaces the prior live pairing failure for basic linked/local chat-list access, but does not prove ongoing sync, message reads, reopen persistence or sends. The previous rejection cause was not established; do not claim diagnostic categories fixed provider authentication. Next public internet/Maps/podcasts grouped read accepted17:34:25.334, still pending at last observation.

## Pairing failure diagnostics installed — September 11, 17:27

Installed safe WhatsApp failure categories in Simulator PID26306. Native bridge now preserves only verification_required, code_expired, client_outdated, or pairing_failed; raw errors never cross to Swift. Swift status accepts only those categories on failed status, shows fixed human-readable text, logs the safe category, and clears the old reason on a fresh start. Unknown errors retain a generic message. This improves diagnosis; it does NOT establish or fix the real phone's post-code rejection. The prior attempt was visibly failed before install. New setup is open, awaiting owner phone entry/approval. Messages/draft match protected backup; outbox0.

Verification: Go regression test failed with five missing-category assertions on current main.go, exit1; green go test -tags wacli ./cmd/wacli-ios-bridge passed exit0. First staging run had stale main.go and was discarded; reran with current worktree source. Swift pairing suite14/14 pass exit0; its new decoding-to-model test was written before implementation, but was not separately run red. Native archive rebuilt from original pinned wacli0.17.1 source; build.sh checksum gates passed and NATIVE_WHATSAPP_SIMULATOR_ARCHIVE_PASS returned exit0. App build12.4s exit0, install/launch succeeded. No live new-error screen verified yet, no account security changes. Logs /private/tmp/operator-pair-reason-{red,green,swift,archive,build}.log. Protected prior library and conversation backup at /private/tmp/operator-pair-reason-archive.PSrxE2. Current WhatsApp connection remains unverified/previous live failure unresolved.

## WhatsApp fails after real-phone code entry — September 11

Owner confirmed “couldn't link device” appears after entering the generated code on the real iPhone. This is beyond the repaired number-format validation. Live Simulator previously stayed codeReady, not linked or finishing. Do not infer successful authentication from code generation.

Relevant upstream report: https://github.com/openclaw/wacli/issues/355 (open when checked). Reporter describes an additional passkey verification step that wacli cannot complete, including phone-number linking. This is a plausible lead, NOT confirmed for this account. Cached wacli source at /private/tmp/wacli-bridge-green.LXD32r pins whatsmeow v0.0.0-20260806224404-e277b766ab33. Its internal/wa/client.go explicitly rejects passkey request/confirmation with descriptive errors. The current ios/build/native-whatsapp/libWacliBridge.a contains those same error strings (verified with strings); unlike the original report, this artifact is not proven to silently ignore the event. Our native bridge execute drops the runner error and returns only phase failed; the UI further reduces failures to a generic message. Thus we cannot establish whether this attempt hit passkey verification, expired code, or a different pairing error from current logs. No new code, retry, account-security change, reset or unlinking performed. Next needed diagnostic is a secret-free failure category from the native bridge before another owner-approved pairing attempt. Existing credentials must remain intact.

## Formatted WhatsApp phone input fixed and installed — September 11, 17:05

Phone-format fix installed in the iPhone 14 Pro Simulator, PID 9040. Spaces (including nonbreaking spaces), parentheses, dots and common dashes are stripped before calling the pairing gateway. An explicit +country code is still required; no country guessed. Invalid input stays editable with a useful explanation, without starting pairing. Regression tests: 13 tests with 17 assertion failures before fix (exit 1), then 13/13 passing (exit 0). Build passed in 14.2s. Live UI test with invalid local input 123 showed guidance and stayed on input screen; input cleared afterward. All 125 messages and original draft equal the protected preinstall backup; outbox 0. Actual formatted owner number still needs to be re-entered and paired; provider success is not yet verified.

Logs: /private/tmp/operator-phone-format-red.log, /private/tmp/operator-phone-format-green.log, /private/tmp/operator-phone-format-build.log. Backup: /private/tmp/operator-phone-format-preserve.uVLHP5/conversation-before.json. No sends, account changes, or live phone submission by agent. Native bridge retains strict canonical-number validation; all UI start/retry paths pass through the changed model. Broader connector goal still incomplete.

## WhatsApp live pairing failed — September 11, 16:52

Owner reported error; Simulator shows “WhatsApp link could not continue” and Try again. Root cause is not yet confirmed. Scoped OS logs for WhatsApp/wacli returned no entries. Source inspection: native-whatsapp/bridge/main.go requires a leading + and 8–15 digits with no separators; WhatsAppLinkSheet.swift neither explains this format nor validates it before submission. WhatsAppLinkFlow.swift catches every start/status error into the same failed state; native Go execute also discards the underlying runner error. Thus this screen alone cannot distinguish rejected phone format from network or provider failure. No blind retry, credential changes, or code changes made. Ask only whether international +country-code format was used, not for the private number itself. The passing 11 stub tests do not establish live pairing. Current WhatsApp result: FAIL, replacing pending status; full connector goal unfinished.

## WhatsApp setup awaiting owner; pairing fixtures pass — September 11, 16:50

WhatsApp setup is visibly open on the iPhone 14 Pro Simulator (iOS 18.6), with an empty Phone number field and disabled Get link code button. Owner must enter their number and approve the linked device; no pairing was started by the agent. Earlier missing WhatsApp menu entry was an accessibility observation issue: a fresh combined screenshot and accessibility capture displayed the entry and it opened successfully. Standalone sh ios/OperatorApp/Tests/capabilities/whatsapp/link/run.sh passed 11 tests, zero failures, exit 0 at 16:50:09; log /private/tmp/operator-whatsapp-link-current.log. Tests use a stub gateway to check code clearing, cancellation, stale results and foreground polling; they do not prove live WhatsApp pairing or message reads. No code changes, rebuild, install or restart during this pending setup. Overall connector setup remains PARTIAL; Weather remains owner-deferred.

## Native Music live read passed — September 11, 16:48

Music permission granted by owner. Fresh music.nowPlaying read returned playing=false and hasTrack=false at 16:48:02.304; Operator displayed Success — 0 items. First text 17.978 seconds; terminal reply 18.386 seconds. No playback changes or track/device details shown. Original unsent draft remains visible. Prior permission-wait timeout is historical; this proves a fresh granted-access read, not automatic recovery of that expired request. WhatsApp pairing and broader reliability checks remain unfinished; Weather remains deferred for Apple Developer enrollment.

## Native Calendar passed; Music permission pending — September 11, 16:45

Calendar permission closed; previous request ended TIMEOUT. Fresh supported empty-parameter calendar.events read returned native event count2 at16:44:33.479; app Success2items, terminal16.112seconds. No event details shown or writes. Next music.nowPlaying read-only request reached iOS Music permission prompt: access Apple Music, music/video activity and media library. No grant made by agent; owner must choose Allow/Don't Allow. No playback controls used. Draft restored. Calendar initial timeout/late app-inactive callback remains historical; successful fresh read proves access, not automatic recovery of expired prompt work.


## Native Calendar permission requested — September 11

Retried native calendar.events with supported empty parameters (fixed seven-day window, at most25events). Operator reached iOS Full Access to Calendar prompt; no grant made by agent. User must Allow Full Access or Don't Allow. This is a read-only test but iOS permission is full calendar access, not read-only. No events created/edited/deleted. Original draft restored. Read result not yet verified; prior invalid-parameter result does not prove a provider failure.


## Photos live read passed — September 11, 16:41

After owner granted access, retried photos.search limit1 through Operator chat. Native foreground-photos log returned count1 partial=false at16:41:06.913; app Success1item, Ready. Firsttext17.747seconds, terminal18.119seconds. No images or photo details displayed in reply; no writes. Original draft restored and visible. Prior timeout result remains historical, replaced by successful read after permission. This proves the granted-access read, not automatic completion of a request whose permission prompt exceeded its deadline. Remaining native Calendar/Music, WhatsApp pairing and broader reliability checks remain open.


## Photos prompt remains unanswered — September 11, 16:40

Fresh AX confirms photo permission choices unchanged. New PID84759 logs: photos.search16:39:18.861, permission_timeout16:39:45.525, terminal chat reply16:39:46.721. Unlike the earlier Contacts immediate node disconnect, no location-node disconnected line occurs after this Photos invocation in the scoped log. One generic gateway disconnected line16:39:36.662 remains unclassified; do not claim every connection stayed uninterrupted. Permission wait lasted about26.7seconds, not immediate cancellation. Owner permission still needed; Photos read success remains unverified, no restart or grant. Retry only after permission choice and inspect terminal reply first.


## Contacts live read passed; Photos permission pending — September 11, 16:39

Owner shared all Contacts. Previous native grouped request ended with calendar INVALID_REQUEST (native calendar accepts no arguments), Contacts timeout, Photos disconnected. Once idle installed tested lifecycle/command-name update, install/launch exit0 PID84759. Protected backup `/private/tmp/operator-permission-install.HlUo1x/conversation-before.json`; all113messages/draft match exactly, outbox0 after install. Notion saved connection restored connected at16:38:35.914. Fresh Contacts lookup Operator limit1 reached service16:39:13.221, returned count0 partial=false16:39:13.265. This verifies full-access lookup, not arbitrary matches. Photos reached service16:39:18.861; iOS now asks Limit Access/Allow Full Access/Don't Allow. No grant by agent. Screenshot capture failed once; full accessibility state successfully confirmed prompt. Photos result and actual permission-interruption recovery still pending. Original draft restored. No external writes or playback.


## Contacts owner choice still pending — September 11, 15:58

Fresh Computer Use confirms the same Contacts permission dialog with Continue/Don't Allow. Owner choice has remained pending across the native test, diagnosis, fix/build, and this recheck. Independent fix/tests/build are complete; no install or duplicate chat request while permission and queued work are unresolved. Mark goal blocked, not complete. Resume after owner chooses Contacts access; inspect queued reply before safely updating and retesting. Full remaining connector scope unchanged.


## Permission interruption fix compiled — September 11, 15:57

OperatorApp.swift now keeps runtimeIsForeground state updated only on active/background transitions; runtime task identity uses that state instead of raw scenePhase. Temporary inactive prompts therefore do not cancel the runtime task or disconnect node; starting while inactive stays disabled. Actual background still suspends. Native service UIApplication active guards and permission decisions remain unchanged. Existing runtime/node logs retained.

Regression in existing setup-after-ready.test.mjs checks real app wiring and executes the extracted phase handler as Swift through inactive/active/background sequences. RED2tests1failure was a missing-wiring assertion, not an OS permission simulation; GREEN2/2. `sh ios/OperatorApp/Tests/chat-reconnect/run.sh` GREEN35/35 exit0, log `/private/tmp/operator-permission-lifecycle-chat.log`. XcodeBuildMCP OperatorApp Debug arm64 build PASS12.0seconds exit0, log `/private/tmp/operator-permission-lifecycle-build.log`. Not installed while Contacts prompt remains pending; actual prompt/background behavior still needs live retest. Source sibling search found account status refresh (kept active-only) and WhatsApp pairing sheet (kept active-only, separate owner-interactive flow); no other app runtime suspension site. Original generic permission_timeout on cancellation remains for genuine cancellation; not changed globally. No commits/pushes.


## Contacts prompt interruption diagnosis — September 11, 15:56

Live timing: contacts.resolve15:54:34.425; location-node disconnected15:54:34.538; Contacts permission_timeout15:54:34.542. OperatorApp.swift:212-232 runs runtimeDidSuspend and foregroundRuntime.setForegroundActive(false) for every phase other than active, including inactive. GatewayDeadline cancellation resolves nil; ForegroundContactsService interprets nil as timeout. This explains the near-immediate timeout when the OS prompt interrupts the scene, rather than a30second wait. Apple ScenePhase docs distinguish inactive (foreground, not interactive) from background (not visible): https://developer.apple.com/documentation/swiftui/scenephase . No code fix yet. Next regression must distinguish temporary inactivity from background suspension while keeping actual background and permission-denial protections; do not merely increase timeout. Permission prompt remains owner-controlled. Need confirm foregroundRuntime cancellation path and test the integrated lifecycle before changing it.


## Native permission check in progress — September 11, 15:54

WhatsApp phone field was empty/Get link code disabled, so dismissed setup without starting pairing to run independent native reads. Chat requested at most1 native calendar event today, contact matching Operator, photo result; counts/errors only, no writes. Native log calendar.events15:54:26.713 and contacts.resolve15:54:34.425. Contacts logs permission_timeout15:54:34.542 while Computer Use still shows iOS Contacts permission prompt; app Saved—waiting for Operator. No contact read success proven. Owner must choose Contacts access; no grant made by agent. Draft restored. Photos and calendar results not yet verified. Investigate premature timeout after permission flow; do not restart or duplicate queued chat until checking current state. WhatsApp setup must be reopened afterward.


## WhatsApp setup opened — September 11

Computer Use opened Connect WhatsApp in Operator. Current UI requests the WhatsApp phone number and provides Get link code (disabled until a number is entered). This flow is phone-number pairing, not a QR screen. No phone number guessed or entered, no link code generated and no linked-device permission granted. User can enter their number directly in the Simulator to keep it out of chat. WhatsApp read tests remain pending pairing; all other outstanding scope remains unchanged.


## Notion signed in; live search returned a result — September 11

Native callback accepted at15:51:16.033. Live Operator chat requested read-only discovery and a small search. UI confirmations exposed notion-fetch with id self, then notion-search with query Operator and page_size1; allowed only these read operations. Chat completed Ready with Success1result. No page contents/titles requested in reply and no edits, comments or other writes authorized. Original unsent draft restored and visible. This proves a live Notion search path, not every Notion tool, refresh, or reopening. Initial fetch result was not separately verified. Corrected account-read error command build remains staged, not yet installed. Other supported connectors and reliability checks remain open.


## Corrected build ready; Notion owner sign-in blocker — September 11, 15:45

XcodeBuildMCP Simulator build of OperatorApp Debug arm64 passed11.0seconds, exit0. Log `/private/tmp/operator-read-command-build.log`; artifact remains `/private/tmp/operator-connectors-setup-build/Build/Products/Debug-iphonesimulator/Operator.app`. Not installed: Computer Use confirms app.notion.com login-choice screen still waiting. Same sign-in blocker checked across three consecutive turns; independent correction and build work now finished. Mark goal blocked, not complete, until owner sign-in. No new provider permissions or app data changes this turn. Remaining scope preserved.


## Retry command name corrected — September 11, 15:44

ForegroundConnectionDiscoveryService.swift:39 confirms actual command `connections.describe`. Corrected missing-limit error in ForegroundAccountReadService.swift:35 and its regression expectation; no API or behavior changes beyond error guidance. RED `sh ios/OperatorApp/Tests/connections/read/run.sh`:28tests10failures, exit1. GREEN same command:28tests0failures, exit0. Logs `/private/tmp/operator-read-command-red.log` and `/private/tmp/operator-read-command-green.log`. Source search for literal `connections.discover` found only the corrected site. Tests cover all ten account-read operations; live model correction remains unverified. Notion still at login choice screen; no install during pending auth. One-word correction not yet rebuilt/installed. Existing fixed-reason logging unchanged.


## Updated app reopened; Notion sign-in opened — September 11, 15:43

Install and launch both exit0; new Operator PID51985. Before installation backed up conversation to protected `/private/tmp/operator-post-slack.9pSoik/conversation-before.json`. After reopening all109messages match exactly, draft matches, outbox0. UI confirms Google/Outlook/Slack/Spotify Connected and YouTube key saved. Native logs show successful token refresh for Google15:42:42.656, Outlook15:42:43.224 and Spotify15:42:43.348. This verifies those refreshes, not Slack refresh or every interruption case. App reached Ready. Notion had missing_tokens; Connect Notion opened loopback15:43:14.510 and app.notion.com login page. Owner sign-in required, no consent granted. Runtime logs also exposed that actual discovery command is connections.describe, while the new missing-limit error says connections.discover: follow-up correction needed; automatic error recovery not yet verified.


## Slack connected; channel read verified — September 11, 15:41

Computer Use confirms Slack Connected alongside Google, Outlook and Spotify; YouTube key saved. Live read-only chat test reached native `slackChannels`, limit1 at15:41:28.087 in Operator PID1594. App returned Channels Success0items; Messages not applicable because no channel was returned. First text16.246seconds, terminal16.553seconds. This proves the bounded channel read, not message-history access or that the workspace contains no channels. No sends, writes, reactions or external test data. Original draft restored and visible unchanged. Existing installed build used; missing-limit update remains staged for safe installation. Remaining connector setup and reliability checks still open.


## Owner sign-in blocker rechecked — September 11, 14:37

Computer Use still shows empty Slack email/password fields at aadivyasagents.slack.com, with Google/Apple alternatives. Same owner sign-in blocker across consecutive goal turns; intervening work completed missing-limit regression tests and staged a passing Simulator build, and resolved the workspace. No useful remaining live check can use this app without interrupting the pending authorization. Mark goal blocked, not complete. Resume after owner sign-in; do not treat the build or fixture checks as connector completion. Other connector setup and reliability obligations remain unchanged; Weather remains explicitly deferred.


## Slack workspace resolved — September 11, 14:36

Authenticated Slack developer app list confirms Operator iPhone belongs to aadivya's agents. Slack sign-in page lists that workspace at aadivyasagents.slack.com. Entered the verified workspace in the existing Simulator OAuth flow and submitted; Simulator now displays that workspace's email/password or Google/Apple sign-in page. Owner sign-in remains needed; no consent granted or credentials copied. Temporary browser tab closed. Build remains staged, not installed. Pending sign-in preserved.


## Simulator update compiled — September 11, 14:35

XcodeBuildMCP simulator build: OperatorApp Debug arm64, iOS18.6 iPhone14Pro UUID49A153C3-BA69-468F-BD21-D827A84E6F07. PASS12.3seconds, exit0; log `/private/tmp/operator-read-limit-build.log`. Artifact `/private/tmp/operator-connectors-setup-build/Build/Products/Debug-iphonesimulator/Operator.app`; bundle ID verified app.operator.ios. Computer Use shows Slack sign-in still at empty workspace URL. No install/relaunch during pending authorization. Missing-limit live recovery remains unverified; no new account activity this turn.


## Missing-limit guidance — September 11, 14:34

Slack sign-in is open; no reinstall or auth interruption. Shared account-read parsing now returns a specific missing-limit correction before credential access, preserving all bounds and provider requests. Test-first: `sh ios/OperatorApp/Tests/connections/read/run.sh` RED 28 tests/10 failures, then GREEN 28/0, exit 0. Logs `/private/tmp/operator-read-limit-red.log` and `/private/tmp/operator-read-limit-green.log`. Red shell wrapper returned the final tail status rather than test status; test output explicitly records failures. New test covers all ten account operations. Safe logs use fixed missing-limit/invalid-input labels, never request bodies. Local code only: actual model automatic correction remains unverified until safe installation after Slack authorization. No claim of complete connector reliability.


## Spotify connected — September 11, 14:19

Live results: search Success1item; first playback call INVALID_REQUEST. Scoped transcript metadata query proves seq198 spotifyPlayback had no limit; seq196 spotifySearch limit1. ForegroundAccountReadService.input requires limit and discovery currently advertises it. Explicit retry with limit1 reached native spotifyPlayback14:21:36.693 and returned Success1item; terminal14.380s. Search/group reply20.646s. No playback mutations. This proves authenticated reads, not reliable omission recovery: agent omitted a required argument despite discovery metadata; that usability failure remains open, no code fix this turn. JSON confirms old messages prefix preserved,draft preserved,outbox0. Screenshot ios-connectors-setup/screens/spotify-read-results.png. Slack remainsCancelled; other connector setup/reliability work remains.

Fresh log confirms phone-local callback accepted14:19:44.210 and Spotify authorization stored14:19:44.351,scopeCount2. Computer Use shows SpotifyConnected; Google/Outlook remainConnected,YouTubeKeySaved. Slack showsCancelled, not connected. Started read-only Spotify search Daft Punk limit1 and playback-status read with explicit prohibition on any playback changes or track/device-detail output. Request accepted17.861ms14:20:21.535; spotifySearch limit1 native request14:20:32.999. Result pending. Original unsent draft visibly restored. No rebuild, restart or additional authorization started.

## Spotify blocker confirmed — September 11, 14:16

Third consecutive goal turn with the same pending Spotify owner sign-in. Fresh screenshot still shows empty email field; logs show ready/listener only, no completion/error. Previous turn was no progress beyond verifying this blocker. Independent YouTube provisioning/live search is complete; no safe remaining account-UI action without replacing this pending flow. Mark goal blocked, not complete, pending owner sign-in/consent. Preserve current session and all remaining scope. No repeated tests, restart or duplicate authorization.

## Spotify owner-input check — September 11, 14:15

Second consecutive observation of this pending Spotify login: screenshot still shows empty email field; fresh logs show authorization ready and local callback listener, no stored authorization or error. Prior turn made progress by provisioning and live-testing YouTube. No new setup/test outcome this turn; remaining account UI work cannot proceed without replacing the pending flow, so leave it intact and wait for owner. No restart, duplicate authorization or repeated fixture tests. Goal remains incomplete; blocked threshold not yet met for this new login blocker.

## YouTube provisioned and live search passed; Spotify login pending — September 11, 14:15

Used existing YouTube-only key resource b3b0d7a1-008a-443c-9b36-780a1265280f from authenticated Google console. No new key or restriction changes. Browser key value stayed in temporary tool variables, never printed; transferred directly into the visible Operator secure field, saved via app Keychain UI, then temporary variables cleared and browser page closed. No repo/config key file or clipboard copy action. UI Key saved verified. This is Simulator-local storage, not physical-device distribution proof. Application restrictions remain None as on preexisting potentially shared key; public-release key-hardening remains open.

Live read-only search for NASA limit1: youtube-media request GET /youtube/v3/search at14:14:38.411, HTTP200 at14:14:38.873, result_count1. Chat displayed Success1result; firsttext12.150s and terminal12.518s. No video opened or played. Original draft restored and saved JSON comparison confirms old messages prefix unchanged,draft unchanged,outbox0. No code changes, build or restart in this turn; existing tested setup UI used.

Spotify Connect started from Operator14:15:03.405, scopeCount2; phone-local loopback listener ready. Computer Use screenshot shows accounts.spotify.com Welcome back email/sign-in page. Owner sign-in/consent required; left flow intact. No Spotify connection or live read claimed. Previous turn was progress (Outlook real reads), this turn progress (YouTube provisioning+HTTP200). Weather remains deferred.

## Outlook connected — September 11, 14:11

Live check completed14:12:27.868. Operator displayed Inbox Success0items and Calendar Success0items; native account-read logs confirm outlookInbox limit1 and outlookCalendarEvents limit1. Firsttext25.663s, terminal27.122s. No account contents or external mutations requested. Saved JSON confirms prior messages prefix unchanged, draft unchanged, outbox0. Screenshot ios-connectors-setup/screens/outlook-read-success.png. This proves the bounded live read flow, not that the entire mailbox/calendar is empty, nor refresh/reopen longevity. No raw provider payload was printed. Remaining setup elsewhere is not complete.

Owner completed verification. Fresh OSLog authorization stored provider=microsoftOutlook scopeCount5 at14:11:00.152; Computer Use shows Microsoft OutlookConnected and GoogleConnected. Started bounded read-only chat test: at most one inbox message and one calendar event today, return only counts/errors, no account contents and no writes/sends. Request accepted397.978ms at14:12:01.145. Native inbox request operationoutlookInbox limit1 logged14:12:16.873. Final results pending. Protected conversation /private/tmp/operator-outlook-read.QqE11k/conversation-before.json. Restored original unsent draft visibly while read is running. No reinstallation/restart.

## Outlook invalid_request after slash fix — September 11, 14:03

14:07 live result: updated app installed/launched successfully PID1594. Conversation cmp exit0 against protected backup after data moved to90737363-311A-41C4-808C-D4B0C2BD5AFE; GoogleConnected visibly preserved. Corrected login opens login.live.com. Entered the already-selected personal Microsoft account email and submitted Return. Computer Use screenshot confirms transition to login.microsoft.com passkey/security-key prompt, NOT dismissal/Tryagain. This verifies the reported email-step failure is resolved for that account. Full sign-in, consent, token exchange and Outlook reads remain pending owner verification. Left passkey prompt intact. First coordinate click failed noWindowsAvailable before typing; refreshed Simulator binding and used focused email field, verified email visually before Return. No passwords, passkeys or codes read/entered. No new permission grant. Full end-to-end Outlook success not claimed.

Live Entra Supported accounts panel reverified Personal accounts only using existing authorized personal browser account. Added testMicrosoftPersonalAccountRegistrationUsesConsumersForLoginExchangeAndRefresh; RED22tests3assertionfailures exit1, GREEN22tests0failures exit0. OAuthTypes.swift changed only authorization and token URL paths common to consumers. Existing log calls remain; no new logger for this two-string change. Sibling search across iOS Swift found only these two original common endpoint uses; refresh shares tokenEndpoint and the regression checks it. No Android edits or provider registration changes. Simulator build exit0 in13.2s, /private/tmp/operator-outlook-consumers-build.log. Protected chat copy /private/tmp/operator-outlook-consumers.UAJBDT/conversation-before.json. Before install UI shows accounts list, no active sign-in. Pending safe installation and live email-step test.

Two new live attempts14:03:04 and14:03:18 accepted documented root slash, then provider invalid_request (no numeric AADSTS code). Prior fix is effective but sign-in still fails. H9: wrong Microsoft authority; current OAuthTypes.swift uses common for authorization and token, whereas live Entra Supported accounts tab for ed4e4e74-ad37-4ddf-a4ca-59d3731be5e6 says Personal accounts only. Official Microsoft troubleshooting table requires consumers for that audience. Competing explanation: another provider parameter is invalid; raw description deliberately not logged, so no claim of full diagnosis of this specific response. Correct the verified configuration mismatch without broadening account audience/scopes or editing Android. Test first that real authorization and exchange/refresh use consumers; current code should fail endpoint assertions. Then fix two endpoints, rerun auth, build and safely install only if no authorization pending. Final owner retry remains necessary. Browser used existing authorized personal session; no registration edits or permission grants.

## Owner-input blocker confirmed — September 11, 14:01

Three consecutive goal turns ended with the same pending Microsoft sign-in requirement: fix/install turn, independent full-Core/YouTube-readiness turn, and this fresh check. Latest Simulator screenshot still shows empty Microsoft email field; fresh OSLog contains authorization ready at13:56:43 and no callback result. Prior turn made progress: full Core79/79 and verified existing YouTube restriction settings. That independent work has finished; repeating it would not advance setup. Do not restart, reinstall, cancel the pending session, or claim Outlook success. Goal is blocked on owner sign-in/consent, not completed. Resume with the resulting callback or owner-directed change; next verify Outlook and then remaining account/native connectors. Weather still deferred. Existing Google connection and preserved conversation were verified after the last install.

## Pending owner retry and independent checks — September 11, 14:00

Full Core suite finished14:01:04: swift test --package-path ios/OperatorCore, exit0,79tests0failures,77.952seconds. Log /private/tmp/operator-core-connectors-final-check.log. No process left in root handle34447. Includes the real local WebSocket keepalive fixture, not Microsoft/Google service calls. Owner Outlook retry is still required.

Previous turn was progress (Outlook fix implemented, tested, installed). Fresh logs still show only Microsoft authorization ready at13:56:43; Computer Use at14:00 confirms empty Microsoft email field. Do not cancel, install or restart during this pending owner flow. Google Cloud credentials page and key detail were checked read-only: existing key resource b3b0d7a1-008a-443c-9b36-780a1265280f, name Operator YouTube Data API active 2026-08-04, selected API YouTube Data API v3 only, application restriction None. No key displayed/copied, no settings or permissions changed. Reuse preparation is not completed app provisioning. Browser detail tab retained for later setup. Do not tighten this shared key to iOS without checking other consumers.

Bundled OpenClaw chat.history schema at runtime/openclaw/dist/src-B9mb84px.js:2006-2032 supports the new history request fields sessionKey,limit,maxChars. Root started full OperatorCore suite; handle34447 is live, expected76second keepalive test verified in URLSessionGatewayTransportKeepaliveTests.swift. This is fixture validation, not a live provider read or completed interrupted-work proof. Weather remains deferred by owner.

## Outlook return-address investigation — September 11

13:56 current result: auth21/21, build14.3s exit0, installed and launched PID92709. Built/installed executable hashes equal. Computer Use confirms GoogleConnected and fresh Microsoft sign-in screen with empty email; owner retry requested. Data container moved AD878699-99AF-4108-BFEC-A5F1C8FE4C2C. First cmp against old path failed (file absent); refreshed path cmp exit0, entire conversation byte-identical to protected backup. Screenshot ios-connectors-setup/screens/outlook-retry-ready.png. No fresh auth result yet. Concurrent cached-reply helper repaired test syntax and final sh chat-reconnect/run.sh35/35 exit0 (/private/tmp/operator-cached-recovery-green.log); focused Core9/9 reported. Behavioral red was not captured by helper, explicitly not claimed. Live recovery remains untested. New build includes Drive discovery fix, ordinary prompt retest pending.

Implemented documented Microsoft root-slash acceptance only; all other redirect and state checks retained, original exchange redirect unchanged. Safe logs now name only standard provider error classes and numeric AADSTS support codes, no raw URLs/descriptions. Auth RED21/3 failed as expected, GREEN21/0 exit0 at13:53:53. Build arm64 Simulator succeeded exit0 in14.3s; /private/tmp/operator-outlook-build.log. Live retest pending. Protected conversation at /private/tmp/operator-outlook-retry.JVVitn/conversation-before.json:99messages,outbox0,originaldraft true. User sign-in sheet dismissed; GoogleConnected still visible. Sibling search found only this path validator; Spotify loopback equality is a different security check unchanged. Accumulated cached-reply tests currently failed compile (await inside XCTest autoclosures); helper is repairing those before root installs the combined build. Direct chat-reconnect/run.sh exit126 (not executable), retried with sh, compile failure exit1; no production compile error.

H8, one variable: Microsoft callback path comparison. Prior belief: likely based on three live callbackRedirectMismatch errors and exact empty-path comparison in PhoneOAuthClient.swift. Competing explanation: a different host or malformed OAuth query; the old log does not distinguish them. Prediction: an anonymous request to the same registered Microsoft client will advertise a slash-ended callback although the submitted redirect has no path. Confirmed: sanitized response field urlAppError=msauth.app.operator.ios://auth/. Official Microsoft reply-url documentation also specifies empty-path redirects return with a slash. No owner credentials were used in this probe. This is evidence of a rejected provider error callback, not proof of successful sign-in; the underlying error remains unknown. Next: regression tests for this documented normalization and retained security checks, then minimal fix, auth suite, build/install and owner retry. Existing auth source/tests clean at HEAD d106bd3; existing worktree contains other ongoing connector edits, preserved in place. No stash experiment: it would disrupt the shared implementation and is unnecessary for the unchanged validator.

## Drive instructions fixed; Outlook owner sign-in pending — September 11

Narrow read-only transcript metadata check confirmed failed Drive invocation seq162: googleDriveFiles, limit1, query absent. Successful retry seq173: same operation/limit, query present (length8). Only operation/limit/query presence surfaced; no credentials or account contents. Discovery advertised query? although DirectAccountReader.valid requires nonempty query. Corrected ForegroundConnectionDiscoveryService.swift readParameters to require Drive query, all read limits and Calendar time bounds; kept actual reader validation and permissions unchanged. Matching sibling parameter declarations corrected, including supported optional cursor. Existing ConnectionDiscoveryServiceTests.swift now asserts the complete required/optional map. Red: discovery harness failed testDescribeUsesLiveSurfaceOperationsAndCatalog on old map. Green: discovery4/4, account-read27/27 exit0 at13:48:31; log /private/tmp/operator-drive-contract-read.log. No new diagnostic logger: this is static discovery metadata and existing request/error logs remain. No new API calls or changed provider parameters. Not built/installed/live retested yet because Outlook authorization is pending. Do not claim the ordinary Drive prompt is fixed live until installed and retested.

Operator Microsoft Outlook Connect opened login.microsoftonline.com in native authorization sheet. Fresh screenshot shows empty Microsoft sign-in field. Owner personal-account sign-in requested; leave flow intact. Google remains connected. No Outlook account access or permission grant yet.

## Google connected and bounded reads — September 11, 13:38–13:41

Operator account sheet shows Google Connected; OSLog confirms authorization finished provider=google state=connected at 13:38:01.890. No installation or restart. Owner completed sign-in. Current app PID54879, data container82C7E4BF.

Read-only chat requested at most one item each for Calendar today, Drive, Gmail and Tasks and only counts/errors in replies. App reported Calendar1, Gmail1, Tasks1; initial Drive INVALID_REQUEST. Source DirectAccountReader.valid requires a nonempty Drive query; exact initial tool arguments were not inspected, so missing query is a likely explanation, not proven. Explicit follow-up Drive search for Operator, limit1, returned Success0. Native request logs confirm Calendar, Tasks and Drive operations with limit1. Gmail's separate implementation has no equivalent request log; Gmail count is the app's displayed result, not an independently inspected provider response. Screenshot: ios-connectors-setup/screens/google-read-results.png. Group reply40.875s; Drive follow-up13.313s. No writes/sends or account content printed. Refresh and Google-specific reopen tests remain pending; no full connector completion claim.

Original conversation protected at /private/tmp/operator-google-read.STarB8/conversation-before.json. Before Drive retry, original message array and original draft both compare equal, outbox0. Draft restored after retry and visibly unchanged. First typed technical prompt was mangled by Simulator typing; not sent. Paste attempt timed out; replaced it with verified plain-language prompt before Send. No test interpretation relies on the malformed prompt.

## WeatherKit deferred to cofounder — September 11, owner decision

Weather integration requires an active Apple Developer Program account and WeatherKit setup. Owner explicitly asked to log this dependency and stop Apple setup for now; cofounder will handle enrollment/account issues. Do not continue Apple enrollment, region, birthday or payment changes. Dedicated Weather cards and attribution implementation remain in place, but live WeatherKit integration is NOT verified. Resume only when the developer account is ready and setup is authorized. This is deferred, not completed. Continue other connectors and request-recovery work independently. Apple requirement: https://developer.apple.com/weatherkit/.

## Plugin link recheck and recovery investigation — September 11

Read-only current-container inspection found both plugin-skills/canvas and plugin-skills/browser-automation valid, targeting current installed bundle 2F0C07A1… with existing SKILL.md files. No repair performed. Bundled plugin-skills-Cq7Uj02-.js:202–245 already republishes generated links, replacing wrong targets at 213–232. workspace-skill-loader-qxQ6sIrH.js:419–456 calls it; skill-root-discovery-DcRwEGr8.js:417–459 requires targets within current plugin roots. This supersedes the earlier broken-link blocker. Current validity does not prove which repair branch previously ran. No app restart or authorization interruption.

Separate recovery finding: bundled chat-send-handler-DBjXcn_1.js:3496–3500 returns cached acknowledgement and stops dispatch when the same request key is retried. GatewayInbound preserves response status (OpenClawGatewayConnection.swift:256–261), but LocalOpenClawChatGateway.deliver discards it and waits for conversation events. Bundled TUI explicitly handles terminal acknowledgement statuses ok/timeout/error (tui-uoixqATk.js:3325 onward). This identifies a source-level recovery gap, not yet a reproduced cause of the earlier empty-final failure. Hypothesis H7: replay of a completed request can wait for an event that will not be resent. Competing explanation for the observed empty-final failure: the upstream interrupted run actually had no readable assistant output. Before changing code, add a focused cached-terminal transport regression; recovery must retrieve a result tied to the same request, not reuse the newest unrelated history entry or repeat a potentially completed write. No speculative fix applied this turn.

## Spotify test-user registration complete — September 11

Browser-read the existing Operator Spotify app, client 2c348c954be24bf68d3680f206625ccd. It remains in Development mode with the existing loopback callback http://127.0.0.1:43827/spotify/callback. User Management initially showed 0/5 users. The signed-in Spotify profile screenshot exposed the owner's email (accessibility text omitted its value); used that verified account rather than guessing from another provider. Added that account as the test user. Fresh User Management state showed “User added”, 1/5 added and the matching account row dated September 11, 2026. No profile, billing, scope, secret, Android registration or callback changes. This permits the account to attempt app authorization; it does not grant account-data access or prove a live API read. Operator sign-in and bounded Spotify read remain pending while Google authorization occupies the Simulator.

Reproduce: open the existing app dashboard → User Management; confirm the single owner test-user row. No new code or automated test surface for this provider-console action. Evidence/report/HTML plan updated; earlier empty-list observations below are historical.

## Google owner sign-in pending — September 11

Fresh Computer Use screenshot shows accounts.google.com, “to continue to Operator”, with an empty email field in the iPhone 14 Pro / iOS 18.6 Simulator. Left the authorization flow open; no restart, reinstall, consent grant or credential entry. This is pending sign-in, not a verified connection or observed authentication failure.

Independent Mac regressions completed: `sh ios/OperatorApp/Tests/connections/auth/run.sh` exit 0, 17 tests / zero failures; `sh ios/OperatorApp/Tests/connections/read/run.sh` exit 0, 27 tests / zero failures. Logs: /private/tmp/operator-auth-check-20260911.log and /private/tmp/operator-read-check-20260911.log. Coverage includes callback validation, scopes, token refresh and bounded reads using test responses. Real Google read/refresh remains unverified. No app code change or fresh build; no new log-captured launch because the pending authorization must remain intact. Next: owner completes Google sign-in, then verify callback and a bounded live read without sending or modifying account data.

## Reminders end-to-end PASS — September 11, 13:03–13:04

Run matching changed LocalOpenClawChatGateway.swift and chat-reconnect/LocalOpenClawChatGatewayTests.swift. Bundled protocol uses idempotencyKey as clientRunId and returns it in acceptance. Buffer pre-acceptance conversation events, then accept only current run ID (response value, fallback submitted key). Safe ignored-run ID logging added. Red32tests/1 failure delivered stale old stream/final; green32/32. No other app consumer of conversation events found. Root arm64 build11.2s passed (build_sim_2026-09-11T18-01-43-084Z_pid53661_f7ab230c.log), installed/launched PID54061/container82C7E4BF. Pre-request message array and draft matched saved snapshot exactly.

Current read: accepted13:03:00.379, native reminders.list13:03:13.888, native count0 at13:03:13.923, first reply15.714s, terminalreply16.240s. Simulator showed Success — 0 items. This is a real current native read plus matching visible reply, not a fixture or prior cached result. Screenshot saved-results/ios-connectors-setup/screens/reminders-success.png. Restored original unsent draft, stopped/reopened app through UI; Ready, same success reply and draft visible. Entire conversation byte-equal after reopen, cmp exit0. Capture helpers ended; Simulator/app left open. Three error entries in successful-run capture are subsequent transport/setup cancellation, not native read failures; later reopen had no separate capture. No reminder mutation or external send. Earlier interrupted request recovery still returned no readable result; this is not proof that every interruption can resume. Remaining provider setup, recovery edge cases, native permissions and live connector checks remain incomplete.

## Reminders native callback fixed; chat matching remains — September 11, 12:57

Changed EventKitReminderStore callbacks to explicit @Sendable and moved conversion to nonisolated static mapping; raw EKReminder stays inside callback. Same annotation added to Calendar, Contacts, Music permission closures. Source-contract regression (not executable background-callback unit test): red17tests/2assertions; second permission assertion red17/1; final17/17. Contacts11/11. Generic helper build failed x86_64 native linking (unsupported NodeMobile architecture); root's correct arm64 build passed11.3s, exit0, build_sim_2026-09-11T17-56-06-111Z_pid50375_de84d508.log. Installed/launched originalSimulator PID50779/container37CD3D3F. Existing message IDs/text/roles preserved; delivery status changes expected on resumed request.

Old queued request recovered but ended unreadable, outbox0. A fresh request was sent12:57:33.575; UI wrongly persisted INTERRUPTED at12:57:33.607 before native tool execution. Actual reminders.list started12:57:45.458, service returnedcount0 at12:57:45.533, result sent12:57:45.535. Process remained alive, no new crash. Native callback/read PASS; chat end-to-end FAIL because old result associated with fresh request. Existing LocalOpenClawChatGateway.deliver accepts all session conversation events without current-run filtering. H6 hypothesis: stale terminal result is consumed by next delivery; prior confidence high from source and event timing. Competing explanation fresh model reply before tool result is possible but cannot explain correct request association without run IDs. Next single change: correlate delivery with current run, test stale stream/final plus legitimate early events before acceptance. Do not reset history/session. Original draft restoredtrue, outbox0. Four error entries include recovered failure and later cancelled transport/setup; not a clean runtime claim.

## Approved workspace recovery and Reminders crash — September 11, 2026

Owner explicitly approved fresh workspace while preserving chat/sign-ins. A one-use local recovery operation removed only agents.defaults.workspace after confirming its target was absent and current workspace empty. Atomic config replacement; verified every other config value and all other state files unchanged. Private original config saved in /private/tmp/operator-before-update.SYmURk/config-before-approved-recovery.json. No state DB reset or account deletion. Runtime prevention source copied into generated runtime and verified byte-equal. Tests12/12; build16.0s succeeded (build_sim_2026-09-11T17-48-40-590Z_pid45753_7fe4c3ad.log), strict signature check passed. Installed on original iPhone14Pro/iOS18.6; new containerCE70EE23. Messages/draft equal to conversation-before-fresh-workspace.json, outbox0 before test. App PID46182 reachedReady. OpenClaw generated .git, AGENTS.md, BOOTSTRAP.md, IDENTITY.md, SOUL.md, USER.md in current workspace.

Fresh bounded Reminders read accepted12:50:03, entered reminders.list12:50:16, then app crashed12:50:20. Crash report Operator-2026-09-11-125020.ips: SIGTRAP, thread22, dispatch_assert_queue then Swift executor assertion then EventKitReminderStore.incompleteReminders callback, invoked by EKReminderStore background completion. This supersedes missing-workspace failure: fresh workspace creation PASS; reminders read FAIL. Account content was not output; actual read result not returned. Current request may remain queued for safe recovery; do not discard it.

H5, before correction: main-actor callback inference conflicts with EventKit's background completion. Prior confidence high from exact crash stack and @MainActor class/callback source. Competing explanation is bad reminder data, lower confidence because crash occurs on executor assertion before mapping. Single change: make callback isolation match asynchronous delivery, retaining value-only mapping. Prediction: background callback regression and same live limit1 request complete without an executor trap. Existing mocked ReminderStore tests did not execute EventKit callback. Apple current fetchReminders documentation and Swift SE0463 completion-handler proposal consulted; no API written from memory.

## Relocation prevention patch — September 11, 2026

Changed native-node/gateway/state.mjs and tests/state/state.test.mjs. New config omits absolute workspace: bundled OpenClaw workspace-default-BBAjKO98.js14–21 uses OPENCLAW_STATE_DIR/workspace. Existing generated JSON paths ending /Operator/openclaw/workspace are migrated only with non-empty surviving workspace contents; old source copied, never removed. Missing old/current content throws without reset. Other custom paths and non-JSON/JSON5 config remain untouched. JSON5 migration is explicitly unsupported, not silently claimed fixed. Original regression failed (helper: stale path unchanged); final state/bootstrap/host tests12/12 and diff check pass. Not packaged/deployed because current workspace has no recoverable contents identified in scoped searches and must not be silently reseeded.

Sibling check also found broken plugin-skills/browser-automation and canvas links to an older app bundle path. They need separate managed-link repair before claiming complete relocation support. Protected backup comparison followed those broken links and printed missing-target warnings; do not claim a clean full-tree comparison from its zero exit alone. No actual workspace reset or sign-in changes occurred.

## H3 — app-update workspace relocation, September 11, 12:25

Follow-up: H3's survival prediction was false. Current workspace directory is empty (including hidden file search), and old6BA7ACCB workspace does not exist. Therefore a path-only fix cannot prove recovery. Upstream workspace-BFk42BX6.js:552–618 explicitly refuses missing/empty recently attested workspaces; do not bypass it. Current 15MB OpenClaw state was cloned after stopping the app into the private backup above. No credential content printed or modified. Draft restored true and outbox0 verified after failed request. Runtime log capture ended; four error-level entries include the failed run and later cancelled transport/config request. The Simulator remains booted; app stopped. Prevention work is separate from recovering the current missing workspace.

Owner granted Reminders permission; screenshot confirmed prompt gone and Simulator controls work again. Reopened old app: previous read had timed out. Restored protected unsent draft and verified on disk (true, 89 messages, zero outbox). Saved private conversation backup /private/tmp/operator-before-update.SYmURk. Current build succeeded in 3.4s, installed and launched on original iPhone14Pro/iOS18.6. Data container changed from 28F5269A to D2913022; byte-equivalent message arrays and draft verified after install. Local gateway/native command surface connected at 12:24:56.

Fresh reminders.list limit1 test failed before tool invocation with WorkspaceVanishedError in 197ms: configured workspace references a still older 6BA7ACCB container. Read-only jq confirmed agents.defaults.workspace retains that old absolute path. Hypothesis H3: prepareState's exclusive creation preserves stale absolute workspace path after iOS relocates the app container. Competing explanation: actual workspace data lost during install (not yet checked). Prior belief: high confidence path issue, based on exact config/error match. Prediction: original workspace content exists in new container, and a relocation fixture preserving that content fails until startup corrects only the managed workspace location. Single change under test: state preparation relocation handling; no reset, reseeding, token rewrite or account data changes. Existing new Weather/YouTube files do not implement prepareState; runtime files unchanged since a916095, so no dirty-tree stash experiment needed.

## Waiting for owner input — September 11, 2026, 12:19

Fresh screenshot `/private/tmp/operator-permission-recheck.png` confirms the original Simulator still displays the Reminders permission prompt. This same owner-consent blocker has persisted across at least three consecutive goal turns. Independent Weather/YouTube implementation checks and public provider readiness checks have been completed without resolving the required account grants. No user reply to the pending consent questions arrived. Marking the goal blocked, not complete; no live-connection claim. Next step is owner decision on Reminders permission, then restore the protected draft and continue the app setup/read flows. Apple Developer sign-in and Google scope registration consent remain pending from their last verified states. Browser handle expiration in this turn is not evidence those sign-ins completed.

## Notion public sign-in discovery — September 11, 2026

Read-only GET checks with `curl --fail --silent --show-error --max-time 20` succeeded (exit 0) for https://mcp.notion.com/.well-known/oauth-protected-resource and https://mcp.notion.com/.well-known/oauth-authorization-server. The resource advertises https://mcp.notion.com as its authorization server. Metadata advertises /authorize, /token and /register on that same host, authorization_code and refresh_token grants, S256 and token endpoint authentication method none. These match the current NotionMCPClient.swift discovery/registration request shape (lines 80–99).

This proves public endpoint reachability from this Mac and current advertised compatibility only. No registration POST, token request, account consent or Notion content read was made. Actual phone-local registration, callback, saved credentials and read remain unverified; registration should happen in Operator so its state and callback remain together.

## Live setup recheck — September 11, 2026, 12:18

The signed-in Spotify account overview now confirms Premium Individual. No subscription, payment or profile settings changed. This resolves the earlier uncertainty about that browser account's plan, but does not yet prove it is the developer-app owner or an allowed test user. The profile page did not expose an email value through accessibility, so no email was guessed or added.

Apple Developer identifiers still redirects to Apple sign-in. Original Simulator 49A153C3 remains booted; fresh screenshot `/private/tmp/operator-current-permission.png` confirms the Reminders Allow/Don't Allow prompt still exists. Computer-use app selection timed out, but direct Simulator screenshot succeeded. No prompt action, reinstall, account grant or live connector read occurred. Next owner action is Reminders permission; Apple sign-in is separately pending.

## Dedicated Weather cards — September 11, 2026

Final full Core rerun: `swift test --package-path ios/OperatorCore`, 77 tests, zero failures, 77.917 seconds, completed 12:17:39. Log `/private/tmp/operator-weather-core-final.log`. This includes the current persisted-card and old-format compatibility tests after the negative control.

Owner chose cards instead of a global footer. Native weather success now saves a structured, independent system message containing the measurements and Apple-supplied attribution URLs. It is not inferred from assistant prose. The old text-only conversation format still decodes; card insertion preserves the draft and queued messages. VoiceOver text includes conditions and temperature.

- H2 negative control compiled successfully; removing only the append statement in a copied package produced 4 assertion failures in the single persistence test at 12:16:22. This verifies test sensitivity, not a pre-implementation regression.
- Current chat test rerun: 31 tests, zero failures at 12:16:37. Command: `bash ios/OperatorApp/Tests/chat-reconnect/run.sh`. Log: `/private/tmp/operator-weather-chat-final.log`.
- Current iOS build log ends `BUILD SUCCEEDED`: `/Users/aadivyar/Library/Developer/XcodeBuildMCP/workspaces/ios-connectors-setup-c256d758e4fc/logs/build_sim_2026-09-11T17-13-47-256Z_pid30000_c7a1acef.log`. Signature verification exit 0.
- Native fixture checks previously completed this session: 22 tests, zero failures, including failed reads and failed persistence. Actual WeatherKit service use remains untested.
- Sibling search for appendWeatherCard, recordCard and WeatherReading found the single app wiring, concrete persistence forwarding, service and Core store. Required callback and persistence contract have no silent production fallback.

Weather UI inspection remains skipped: Simulator computer-use access timed out three times. This is not a visual or legal-compliance pass. Apple Developer sign-in, WeatherKit provisioning, actual attribution rendering, offline image behavior and VoiceOver link navigation remain unverified. The original Simulator permission prompt was not interrupted.

## H2 — card persistence behavioral test, September 11

Before experiment: hypothesis H2 is that the new persisted-card test actually detects a missing card write. Single change: in an isolated copied Core package only, remove the append statement from appendWeatherCard while leaving the new types and test intact. Prior belief: high confidence. Prediction: package compiles, but testWeatherCardPersistsAsAnIndependentSystemMessageAcrossRelaunch fails attachment/role/count assertions. Production files remain unchanged. Scratch path /private/tmp/operator-weather-card-red.nS3jub.

## Slack readiness and runtime follow-up — September 11, 2026

Slack's existing Operator iPhone app A0C0LS6HLJX loaded in the developer browser. It lists the expected custom callback app.operator.ios://oauth/slack and all eight user scopes matching OAuthTypes.swift: chat:write, channels:read, channels:history, groups:read, groups:history, im:write, im:history, users:read. Bot scope list is empty. No installation, token reveal, new grant, setting change or workspace data read performed. Actual app sign-in and bounded read remain pending.

The second clean-Simulator OSLog capture showed an older model setup request failing with cancellation at 12:06:08; the next log explicitly says that generation-1 failure was ignored, after generation 2 had successfully read configuration at 12:05:22. This narrows that one error to an older request, not proof of current setup failure. Other runtime errors and full recovery remain unverified. Simulator CUA inspection timed out three times even after opening its window with XcodeBuildMCP; no restart/erase attempted.

## YouTube setup on a clean Simulator — September 11, 2026

Created isolated iPhone 14 Pro / iOS 18.6 Simulator Operator Connector Setup Checks, UUID 9ABE5E57-7969-46F7-BD19-84B5B7F70597. Available disk was 72 GiB before creation. Installed final setup build successfully and launched with XcodeBuildMCP log capture. Original 49A153C3 Simulator and its permission prompt were not changed.

CUA exercised Connections → YouTube. Secure field masked a deliberately fake value (`operator-ui-test-not-a-real-key`), Save became enabled, saving cleared the field and showed saved state. Stopped/relaunched app; Connections still showed Key saved and the field did not expose the stored value. Removal required confirmation; after confirming, setup-required screen returned. This proves real Simulator Keychain save/load/delete for the fake value; no provider request or real credential was used. Light and dark screenshots are in ios-connectors-setup/screens/ under saved-results.

Runtime evidence: youtube-setup logged key saved on first launch; second launch logged usable=true at 12:05:39 and key removed at 12:06:13. No youtube-setup error events seen. Captured OSLog files contained 12 and 3 error-level events respectively, from gateway/model/node interruptions, including cancelled requests. These were not diagnosed as part of the storage UI check; do not claim a clean runtime or account recovery success. No UI crash observed. Actual YouTube search remains untested.

Stopped app and shut down only this new Simulator after checks; all four reported log helper PIDs were absent afterwards. Test Simulator retained for reuse. Screenshots: youtube-saved-light.jpg and youtube-cleared-dark.jpg. No real user data removed; only the synthetic test key was deleted.

Owner chose dedicated Weather cards. Implementation is proceeding with structured native results, not parsing model prose, while provider consent/sign-in requests remain pending.

## YouTube secure setup implementation — September 11, 2026

Isolated codex/ios-connectors-setup adds secure YouTube key entry in Connections, storage status, replacement and confirmed removal. Existing media Keychain service/account retained; no real key acquired or stored. Safe operation-only logging added.

- Behavioral red before implementation (helper): 4 tests, 10 assertion failures.
- Initial parent run: 5 tests, zero failures.
- Expanded helper run: 9 tests, zero failures, including storage errors and exact UTF-8 boundary cases. Command: ios/OperatorApp/Tests/connections/media/youtube/run.sh.
- Parent media integration: 17 tests, zero failures. Command: bash ios/OperatorApp/Tests/connections/media/run.sh.
- Final iOS build via XcodeBuildMCP: exit 0, 13.6 seconds. App: /private/tmp/operator-connectors-setup-build/Build/Products/Debug-iphonesimulator/Operator.app. Strict signature check exit 0; git diff --check clean.
- Not installed. Main iPhone 14 Pro Simulator still waits for owner Reminders consent. Visual UI checks, real Keychain storage, actual YouTube search and reopening remain unverified. In-memory tests do not prove these.

Provider setup observations are retained in the prior ios-connectors worktree's evidence file: Google Tasks enabled; YouTube-only key exists; Google Data Access empty; Apple login needed; Microsoft callback/personal account support confirmed; Spotify callback correct but no test users listed. No further external settings changed during this implementation.

## Combined collaborator updates — September 11, 2026

Integrated all four incoming commits through c573334 on top of local checkpoint4d0c8a2, preferring their completed test fixes. Retained local auth scope/cancellation, Notion timing and four-command routing fixes. Corrected incoming GatewayDeadline so a callback ignoring cancellation cannot hold up the caller; behavioral red2failures, focused green4/4.

Final checks all exit0: Core75, native20, contacts11, reminders16, account-read27, auth17, setup6, Notion-node9, discovery4, Node23. App build succeeded33.7s, strict signature verification passed, three plist/project checks OK, diff clean. Logs /private/tmp/operator-combined*.log. No live install/account grant or public push during integration. Existing permission/account blockers remain, not proof of all connectors working live.

## Repair and live check — September 11, 2026

Final regression batch all exit0: native15, reminders14, node-policy3, read23, discovery4, write9, media17, confirmation6, notion15, notion-callback7, notion-node9, spotify-loopback6. Loop completed; no live process remains. Node checks23/23, three plist/project validations OK, diff check clean. Invalid helper shell attempts and a stopped duplicate are excluded from these passing results. Reminders consent, other live native reads, account logins/reads and merge still await completion.

Auth follow-up: partial saved scope sets now throw reauthorizationRequired without refreshing or deleting credentials; system browser cancelled-login errors become CancellationError. Behavioral red in isolated copied old implementations: auth 17 tests/1 failure (Expected error); setup 6 tests/1 failure (cancellation type assertion). Current green auth17/setup6, zero failures. Combined Simulator build succeeded12.6s; strict signing passed. Build not installed while Reminders consent prompt awaits user.

Latest: four-command policy fix is installed. Policy regression red 1/1; green 5/5. Full Core **71/71**, exit 0, 77.561 seconds (corrected from helper's mistaken 70 count by inspecting the final log). Contacts conflicting test red 1/9, then green 9/9 after requiring bounded lookup routing while still rejecting listing. Build 13.2s, signature verification exit 0, install/launch exit 0. Logs verify exact native approval and connected surface. **device.status now succeeds live**, confirmed by response and native log. Reminders limit-1 check reached iOS permission prompt; owner consent requested. Earlier node-failure statements below are the reproduced failure, not current state.

Supersedes original failures below. Test-only repairs passed: native 15/15, account reads 23/23, OAuth 15/15 (including rejection of old incomplete Google scopes), discovery 4/4, Core 70/70 (exit 0, 77.613s), Notion node 9/9 on three consecutive runs. The Notion timing bug was reproduced with a 20ms credential-store delay before fixing synchronization. Exact change details are in the HTML report.

XcodeBuildMCP Simulator build succeeded in 30.6s; install/launch exited 0, PID 75827. Initial post-install conversation file matched pre-install SHA256 exactly: 82 messages, no queued messages, unchanged draft. Existing public native Node/OpenClaw and WhatsApp build inputs were copied, not private account state.

Live result: device.status returned `node not connected`. Simulator logs repeatedly report `rejected unexpected pending surface` then `invalidFrame`. Read-only inspection of the OpenClaw SQLite pending command list found 22 commands, missing `contacts.resolve`, `photos.search`, `music.nowPlaying`, `music.search`. The current explicit policy omits these names; actual bundled OpenClaw defaults differ. Regression/fix work is underway; no live database changes or relaxed approval checks.

Google showed Connected before update, Connect afterwards. Sign-in reached Google's email entry and was cancelled; no credentials entered. Logs report only PhoneOAuthError, insufficient to establish the cause. No live account read is proven.

UI test incident: accessibility setValue changed displayed text but Send used the persisted original draft. Stopped immediately; one copy of the draft was added to local chat. Restored the exact unsent draft using normal typing and verified its saved hash. Subsequent test input was checked against persisted draft before Send. No history deleted or external write performed. Further testing must use normal typing and verify persisted input.

Merge, native permission checks, account reads, dependency pinning and physical-device checks remain incomplete. Goal remains active. Android is unchanged.

## Fresh Mac run — September 11, 2026

Tested commit `d1c3cc52717218302aafaa11150c86a5659d4174` in a separate `ios-connectors` worktree. These results supersede “not run on Mac” statements below, but do not establish any live connection. No source fixes, commits, pushes, Simulator install or account actions were performed.

| Command / suite | Exact result |
| --- | --- |
| `bash ios/OperatorApp/Tests/capabilities/reminders/run.sh` | exit 0; 14 passed |
| `bash ios/OperatorApp/Tests/capabilities/contacts/run.sh` | exit 0; 9 passed |
| `bash ios/OperatorApp/Tests/capabilities/native/run.sh` | exit 1; compile error, no tests ran |
| `bash ios/OperatorApp/Tests/connections/read/run.sh` | exit 1; compile errors, no tests ran |
| `bash ios/OperatorApp/Tests/connections/discovery/run.sh` | exit 1; 4 tests, 1 failure |
| `swift test --package-path ios/OperatorCore` | exit 1; 70 tests, 8 failures |
| `connections/auth/run.sh` (with `bash ios/OperatorApp/Tests/` prefix) | exit 1; 14 tests, 3 failures |
| `connections/write/run.sh` | exit 0; 9 passed |
| `connections/media/run.sh` | exit 0; 17 passed |
| `connections/confirmation/run.sh` | exit 0; 6 passed |
| `connections/setup/run.sh` | exit 0; 5 passed |
| `connections/notion/run.sh` | exit 0; 15 passed |
| `connections/notion-node/run.sh` | exit 1; 9 tests, 1 failure |
| `connections/notion-callback/run.sh` | exit 0; 7 passed |
| `connections/spotify-loopback/run.sh` | exit 0; 6 passed |
| Clean-clone Node suites from `.github/workflows/ios.yml` | exit 0; 23 passed |
| `plutil -lint` on app plist, widget plist, Xcode project | exit 0; all three OK |

Failure details:

- `Tests/capabilities/native/NativeReadServiceTests.swift:216`: awaited call inside `XCTAssertEqual`; XCTest's assertion cannot await it.
- `Tests/connections/read/DirectAccountReaderTests.swift`: the same assertion problem at lines 59, 165–166, 170, 176, 226, 322 and 360. Await values into local variables before asserting (suggestion only, not changed).
- Discovery `ConnectionDiscoveryServiceTests.swift:24`: old read-operation expectation omits added Gmail, Tasks and Outlook Calendar entries.
- Core: policy expectations at `GatewayNativeNodePolicyTests.swift:19,53` do not include the expanded allow-list; pairing tests get `invalidFrame` (three thrown errors plus a rejection mismatch); `OpenClawNodeConnectionTests.swift:47–48` expects the old families/commands. These failures require reconciliation with the intended command surface, not automatic weakening of tests.
- Auth: code-exchange, Google callback and Microsoft token-response tests throw `invalidTokenResponse` at `PhoneOAuthClient.swift:70`. The branch added required scopes; fixture response scope lists need investigation. This does not prove the live Google login cause.
- Notion setup: `NotionNodeTests.swift:18`, `testSetupMissingRedirectUsesLocalCallbackBeforeDiscovery`, sees 0 instead of expected 1. Cause not determined; do not dismiss as flaky without evidence.

Tool access is now available: installed XcodeBuildMCP 2.7.0 and added a global Codex stdio entry with telemetry disabled. `xcodebuildmcp simulator list --output json` exited 0 and found the booted Operator iPhone 14 Pro, iOS 18.6. No device state was changed. The current chat can use its CLI; the newly configured native MCP tools have not been hot-loaded into this chat. Build/install/live stages were not run after the failing Stage 0 suites. See the local [HTML test report](ios-connectors-mac-test-review.html) for the full human handoff.

Updated 2026-09-10. Branch `codex/ios-connectors`.

Phases 0, 2, 3 and 4 of the plan are written and locally verified. Phase 1 (live
authorization) and Phase 5 (writes) are untouched — Phase 1 needs the Mac, and
Phase 5 is gated on Phase 1 by the reads-before-writes rule.

**Read the columns literally.** "Fixtures" means a test suite passes. "Live"
means a person watched a real account answer through Operator. Nothing in the
second column is claimed by anything in the first, and no row below has a live
result yet, because the machine this work was written on has no Xcode.

## What ran, and where

| Check | Where | Result |
| --- | --- | --- |
| `go test ./companion/...` | here | pass, 0 failures |
| `node --test` (catalog completeness, commerce safety, project sources) | here | pass, 3/3 |
| Service and reader logic, ported to swift-testing | here | pass, 39/39 |
| `swiftc -parse` on the committed XCTest suites | here | pass |
| `Tests/**/run.sh` (the committed XCTest suites) | **Mac** | **not run — XCTest ships with Xcode** |
| `swift test` (OperatorCore) | Mac, 2026-09-11 | pass, 81/81 |
| `xcodebuild` + `simctl install` + launch | Mac, 2026-09-11 | **BUILD SUCCEEDED**, installed, paired |
| ChatGPT device-code sign-in | Mac, 2026-09-11 | **authorized live** |
| Reminders permission granted on a real call | Mac, 2026-09-11 | **granted** — `kTCCServiceReminders\|2` |

The 39 swift-testing checks are a local port of the committed XCTest
assertions, written to verify the logic on a machine that cannot run XCTest.
They exercise the same code paths and the same expectations. They are not the
committed suites and they are not evidence that the committed suites pass.

## Per connector

| Connector | Tier | Fixtures written | Fixtures green on Mac | Authorized live | Real read | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Apple Reminders (`reminders.list`) | 0 — no OAuth | yes | **no** | **yes** — prompt shown and granted | **partial** | Command reaches the handler and returns cleanly; see 2026-09-11 below |
| Contacts (`contacts.search`) | 0 — no OAuth | yes | **no** | **no** | **no** | Renamed from `contacts.resolve` so openclaw can pair it |
| Device (`device.status`) | 0 — none | yes | **no** | n/a | **yes** | `returned online=true lowPower=false` through a real agent call |
| Microsoft Calendar (`outlookCalendarEvents`) | 1 — scope only | yes | **no** | **no** | **no** | Forces Microsoft re-consent; see below |
| Gmail (`gmailMessages`) | 1 — scope only | yes | **no** | **no** | **no** | Forces Google re-consent; see below |
| Google Tasks (`googleTasks`) | 1 — scope only | yes | **no** | **no** | **no** | Kept |

### Google Contacts and Chat were dropped, 2026-09-11

Built, then removed before anyone authorized them, on the principle that the
phone already supplies the same data for free:

- **Google Contacts** duplicated `contacts.resolve`, which reads the phone's own
  address book with no OAuth, no review and no annual re-verification — and on a
  consumer iPhone that book is usually already synced from Google.
- **Google Chat** is a Workspace product with thin consumer use: two scopes
  reaching message content, for the narrowest audience of anything on the list.

The remaining Google scopes are `calendar.events`, `drive.file` (the narrow
per-file scope), `gmail.readonly` and `tasks.readonly`. A test pins the two
dropped families out so reinstating either has to be an argument.

### Google scope debt

**Correction, 2026-09-11.** An earlier version of this section, and the commit
message for the Google connectors, stated flatly that `gmail.readonly`,
`contacts.readonly` and both chat scopes are *restricted* and that `drive.file`
is among them. That was asserted from memory, not checked, and `drive.file` in
particular is the deliberately narrow per-file scope — Google's own reference
describes it as "only the specific Google Drive files you use with this app",
which is the cheap alternative to the broad Drive scopes, not a costly one.

What was actually verified on 2026-09-11, by reading the pages:

- Google's public OAuth scope reference carries **no** sensitive/restricted
  labels at all. The classification is not there to be read.
- The API Services User Data Policy confirms "Sensitive and Restricted Scopes"
  exist and carry **Limited Use** obligations, and that apps requesting
  restricted-scope data need **annual re-verification**.
- The per-scope classification lives in each product's own policy and in the
  OAuth Application Verification FAQ. It was not confirmed for these scopes.

So: the exact tier of each scope is **unconfirmed** and should be settled from
the verification FAQ before any launch planning depends on it. What is not in
doubt is the direction — more Google scopes means more verification work, and
four of the scopes now requested reach personal content.

### The Limited Use question this raises

The User Data Policy requires that use of scope data be limited to user-facing
features, that transfers to third parties are prohibited except to provide
those features with the user's consent, and that humans must not read the data
without the user's affirmative agreement.

Operator sends message and contact content to **OpenAI** for inference
(`LocalModelSetupGateway.swift:109`, `openai-device-code`). That is a transfer
to a third party. It is plausibly inside the "to provide your user-facing
feature, with consent" exception — it is how any assistant works — but it is a
live compliance question, it needs a lawyer's read rather than an engineer's,
and it needs a consent flow that actually says so. It is the same shape as the
Apple DPLA §3.3.3(J) collision already recorded in
[phase0-ios-capability-ceiling.md](phase0-ios-capability-ceiling.md).

## Native iPhone connectors (Tier 0)

Added 2026-09-11, completing the base set. None needs OAuth, a registration or
a review; each needs a permission string, and one needs an entitlement.

| Connector | Command | Permission | Notes |
| --- | --- | --- | --- |
| Photos | `photos.search` | `NSPhotoLibraryUsageDescription` | Returns descriptions only — ids, dates, kinds, albums. **Never image data.** Partial access reported |
| Music | `music.nowPlaying`, `music.search` | `NSAppleMusicUsageDescription` | The owner's own library. No playback verb: playback is a write |
| Weather | `weather.forecast` | none | Takes an explicit coordinate; does not read location. **Needs an entitlement — see below** |
| Device | `device.status` | none | Battery, power, connectivity, locale, time zone. No identifier of any kind |

`weather.forecast` and `device.status` are in `commandPolicyAllow`; a public
fact about a caller-supplied coordinate and a device state carrying no
identifier are not personal data. Photos and Music are not, and follow
calendar, reminders, contacts and location.

### WeatherKit needs more than a permission string

`com.apple.developer.weatherkit` must be enabled on the App ID, which requires
a paid Apple Developer account. Unlike everything else in this table it cannot
be satisfied from source, and without it every call fails at runtime. Apple
also requires visible attribution wherever the data is shown; the service puts
the attribution string in its own payload so it cannot be lost on the way, but
**rendering it is an outstanding UI debt.**

### A bug this work surfaced in already-shipped code

`JSONSerialization` bridges `0` and `1` to an `NSNumber` that satisfies
`is Bool`. The obvious guard against `{"limit": true}` therefore also rejected
`{"limit": 1}`, and **Reminders and Contacts refused a limit of exactly one**
from the day they shipped. Weather would have refused the coordinate 0,0.

Fixed by `OperatorCore.JSONNumber`, which uses `objCType` — the idiom
`ForegroundAccountReadService` already used — in one place instead of five. A
regression test pins every affected boundary.

## Hand-off connectors (Phase 4)

Eight added, taking the pack from 76 to 84: Gmail, Google Calendar, Slack,
Notion, Waze, Zoom, Ticketmaster, Instacart. These are a different kind of
thing from the four above — they open an app or its website and can never do
more, so "live authorization" does not apply to them. What *was* verified:

| Check | Result |
| --- | --- |
| Play Store id resolves | all 8 answer 200 |
| The check discriminates | a fake id answers 404, and the run reproduced the two 404s already recorded in the source (`com.lyft.android`, `com.viator.mobile.consumer`) |
| Destination answers over HTTPS | 8 of 9 candidates; Yelp answers 403 to any non-browser request and was left out rather than recorded as unverified |
| Go, Kotlin and iOS catalog agree | `catalog-completeness` pins the id sets to each other and passes |
| No prohibited service or commerce path | `commerce-safety` passes |

Still unproven: that any of them actually opens on a device. That needs the
Mac, like everything else in the second column.

## Reproducibility (Phase 0)

`ios/Runtime/bootstrap.sh` now exists, with `--check` and `--pin` modes that
work without Xcode, and [DEPENDENCIES.md](../ios/Runtime/DEPENDENCIES.md)
records all three artifacts.

**NodeMobile is still unpinned.** The script refuses to stage it until someone
runs `--pin` against an artifact they downloaded themselves and records the
hash. That is the one remaining step before a second machine can build.

A CI workflow (`.github/workflows/ios.yml`) runs every check that does not need
Xcode. The Swift suites are still a Mac step.

## Two things the first Mac run will hit

**Both Microsoft and Google now demand a re-consent.**
`requiredAccessTokenScopes` is a hard gate at `PhoneOAuthClient.swift:242`, so
a token granted before `Calendars.Read` and `gmail.readonly` existed will fail
validation. Whether the restore path degrades cleanly to "needs setup" or
surfaces an error is **unverified** and is worth watching on the first launch.

The connectors plan sequences Tier 1 after the existing sign-ins are proven for
this exact reason. The handoff records Google as currently failing with "Try
again". If that is still true, revert `ac30d7c` (the gmail.readonly scope, kept
as its own commit so it can be reverted alone), fix sign-in against the existing
scopes, and put it back afterwards.

**The pairing surface changed.** `reminders.list` and `contacts.resolve` were
added to `GatewayNativeNodeSurface.commands`, which is matched exactly against
the gateway's stored surface. An already-paired node will need re-approval.

Neither new command was added to `commandPolicyAllow`. That is deliberate and
follows `location.get` and `calendar.events`: personal data is never added to
the policy Operator installs into the gateway on the owner's behalf.

## What is not started

Writes. Every connector above is read-only, per the plan's reads-before-writes
rule, and no write path should be written until each row above has a real read.

---

## 2026-09-11/12: first live connector calls, and what the MVP still needs

### Rows that moved

`device.status` is the first connector with a genuine end-to-end result: an
agent call reached the handler and it answered `online=true lowPower=false`.
`reminders.list` reaches the handler and returns cleanly, and iOS raised and
recorded the Reminders permission - `kTCCServiceReminders|2`, where before
there was no TCC row for the app at all. It is marked **partial** rather than
proven because the answer has not yet come back through chat as text a person
read; see the rate limit below.

Three defects had to be fixed before any of that was possible, each hiding the
next: the node published no agent tools (e90bcf9), the first real EventKit
call trapped on a `@MainActor` executor check (032c192), and the gateway
websocket was capped at a 30-second total lifetime (b4ac9e1).

### Still unproven, and why

- **The five OAuth sign-ins.** Phase 1 of the plan is untouched. The device
  log still reports `saved connection unavailable` for `microsoftOutlook`,
  `slack` and `spotify` on every launch. Nothing in Tier 1 - Gmail, Outlook
  Calendar, Google Tasks - can be proven until this is.
- **`contacts.search`, `photos.latest`, `music.*`, `weather.forecast`.**
  Written, published as tools, never called live. Contacts needs no fixture
  (the simulator ships six sample people), so it is the cheapest next proof.
- **`music.*` cannot be proven on a simulator at all** - there is no media
  library. It needs a device.
- **`weather.forecast`** still needs the `com.apple.developer.weatherkit`
  entitlement, which needs the $99/yr Apple Developer Program.

### What blocks the next session

The ChatGPT account is rate limited. Runs return `blocked` / `run_blocked`
within about two seconds without reaching a tool, and the app shows
"API rate limit reached." It persisted across two and a half hours, so it
looks like a daily or plan-level cap rather than a short window. Ruled out
first: session transcript (cleared the state DB and conversation, same
result) and tool-schema quarantine (no quarantine record exists).

### Two bugs found but not fixed

- **openclaw bakes an absolute workspace path** into
  `agents.defaults.workspace` at first init. Any reinstall changes the data
  container UUID and the runtime then dies with `WorkspaceVanishedError`.
  Dev-only - an App Store update keeps the container - but it bites on every
  `simctl install`. Workaround: rewrite the key before launch.
- **A stray "UI probe reminder"** is in the simulator's Reminders list from
  fixture work. Cosmetic; delete before filming.

### MVP gaps that are not connector work

- **No settings or permissions surface exists** (issue #23). There is no
  screen anywhere in `OperatorApp/Sources` that lets a person see or revoke
  what Operator can reach. Every limit we ship is currently invisible and
  unchangeable from inside the app.
- **The evidence rule still holds.** A row may only leave `unproven` when a
  human watched it happen. Most rows above are still machine-observed only.

---

## 2026-09-14: first run on a physical iPhone

Device: iPhone 17 (`iPhone18,3`), iOS 26.6.2, free Apple Development
signing, team set in the gitignored `Local.xcconfig`. Automatic provisioning
created the `app.operator.ios` profile on the first device build, so the
bundle ID was not held by another team.

### What was proven

| Check | Result |
| --- | --- |
| Device build signs | yes — `Apple Development`, `get-task-allow` |
| Embedded Node boots under the iOS sandbox | **yes** — the open question from 261f925 |
| Gateway ready on a fresh install | yes, 10.8s |
| Gateway ready on relaunch with existing state | yes, 7.5s |
| Chat websocket connects, `sessions.messages.subscribe` completes | **yes** — first time on a device |
| Node connects, publishes 8 agent tools, surface approved | yes |
| ChatGPT sign-in, any connector call | **not yet** — nothing below the runtime has been exercised |

### Three sandbox failures, each hiding the next

All three read as the same "Operator's bundled runtime could not start."
The status file gave the stage and bundled frames; the phone's own log gave
the cause each time, as a one-line `Sandbox: Operator deny(...)` entry.

1. **`/tmp` is outside the sandbox** (fb809a0). openclaw hardcodes `/tmp` for
   its lifecycle lock database. Patched at staging time to honour
   `OPERATOR_STATE_LOCK_DIR`, which the host sets to `<state>/locks`.
2. **The container root is not writable** (ad64a31). openclaw's read-only
   SQLite snapshot root is `~/.cache/openclaw`; on iOS `~` is the container
   root, where only `Documents`, `Library` and `tmp` may be created. Fixed
   with `XDG_CACHE_HOME=<state>/cache`, which openclaw already honours.
3. **iOS re-homes the data container on every install** (ee768a7). The
   recorded `WorkspaceVanishedError` bug, now fixed in `prepareState`.

### Two facts worth knowing before touching the runtime again

- **`process.platform` is `"ios"` under NodeMobile, not `"darwin"`.** Every
  `=== "darwin"` branch in openclaw is skipped on the phone (and, presumably,
  on the Simulator). The `.cache` path above is how this surfaced.
- **The Simulator hides every one of these.** Its `/tmp` is the Mac's, its
  container sits on a filesystem that allows dotfiles at the root, and its
  container UUID is stable across `simctl install` most of the time. A
  Simulator pass says nothing about the sandbox.

### How to read the phone

`xcrun devicectl` cannot stream logs. What worked, with no sudo and no
system install:

```sh
python3 -m venv pmd3 && pmd3/bin/pip install pymobiledevice3
NO_COLOR=1 pmd3/bin/pymobiledevice3 syslog live -m Operator
```

Then relaunch and grep for `Sandbox: Operator` and `[embedded-runtime]`.
The runtime's own status file is at
`Library/Application Support/Operator/openclaw/native-runtime-status.json`
in the app container, readable with `devicectl device copy from`.

One benign denial remains in every launch: `deny(1) process-fork`. Something
in openclaw tries to spawn a child at startup and carries on when refused.
Not investigated.

---

*The sections above were written on the phone-bringup branch (`codex/ios-connectors`);
the sections below on the Simulator verification branch (`codex/ios-connectors-setup`),
over the same days, and were merged on 2026-09-14. Where they disagree about command
names, the phone branch's `contacts.search` / `photos.latest` are current — the Simulator
branch's `contacts.resolve` / `photos.search` never paired with openclaw.*

---

# Verification session — 2026-09-11 (branch codex/ios-connectors-setup)

Goal that framed this session: prove the open connector items work — every one
except Weather (blocked on Apple Developer enrollment, owner aware). Plan file:
`planning/ios-connector-verification-goal.md`.

## Headline: the Xcode test target was only running 8 of 30 test files

The biggest thing found this session is not a connector bug — it is that
`xcodebuild test` on the committed project was **silently skipping most of the
connector test coverage**. The committed `Operator.xcodeproj` referenced only
**8 of the 30** test files under `OperatorApp/Tests/`. The other 22 (Drive/Gmail/
Spotify/Outlook reads, OAuth refresh, Notion, account writes, confirmation,
handoff, and more) were never compiled into `OperatorAppTests`. They ran **only**
through the per-area `run.sh` scratch-package harnesses. So the app's own test
target — what CI would run — gave a false sense of coverage.

Cause: the test files were added after the project was last generated, and
`xcodegen` was not installed, so nobody regenerated. The pbxproj uses explicit
file references (no synchronized folder group), so new files are invisible until
a regen.

Fix (all durable in `ios/project.yml`, so it survives future regenerations):
- Regenerated the project with `xcodegen 2.46.0` → all **30/30** test files now
  compile into `OperatorAppTests`.
- Pinned `TEST_HOST`/`BUNDLE_LOADER` to `Operator.app/Operator`. The app's
  `PRODUCT_NAME` is `Operator`, but xcodegen 2.46 derived the test host from the
  target *name* (`OperatorApp.app`), which fails the build with "Could not find
  test host". Pinning the real path keeps every regeneration runnable.
- Excluded the harness scaffolding from the target: `**/*.sh`, `**/*.template`,
  `**/*.mjs` (their many same-named copies collided as bundle resources —
  "Multiple commands produce run.sh"), and the one standalone `@main` check
  executable `runtime/embedded/endpoint/LoopbackPortChecks.swift` (not an XCTest;
  its `@main` collides in a test bundle).

Result — full app test target, on a throwaway Simulator (iPhone 16 Pro, iOS
18.6; the live "Operator iPhone 14 Pro" sim was left untouched):

    xcodebuild test -project ios/Operator.xcodeproj -scheme OperatorApp \
      -destination 'platform=iOS Simulator,id=<iPhone 16 Pro>' \
      -only-testing:OperatorAppTests CODE_SIGNING_ALLOWED=NO
    => ** TEST SUCCEEDED **  Executed 341 tests, 1 skipped, 0 failures

The 1 skip is a source-shape check that can only run where the source is on disk
(see below). Ran the full suite three times to shake out flakes; green each time
after the fixes below. (A benign warning about saving the .xcresult bundle can
appear when DerivedData is in a scratch dir — it is a filesystem artifact, not a
test failure: TEST SUCCEEDED, XCODEBUILD_EXIT=0.)

## Latent bugs the drift was hiding (found only once all files compiled together)

- **`NotionMCPClient.listTools()` was ambiguous.** `NotionMCPClient` has two
  `listTools()` overloads differing only by return type — the raw MCP one
  (`-> NotionJSONValue`) and the `NotionNodeClient` conformance in
  `ForegroundNotionService.swift` (`-> [NotionTool]`). `NotionMCPClientTests`
  discarded the result (`_ = try await client.listTools()`), which can't pick an
  overload. The scratch package never compiled `ForegroundNotionService.swift`,
  so it never saw the second overload. Fixed in the test by naming the type.
- **`ForegroundRemindersServiceTests` read a source file at a scratch-only
  path.** `testEventKitFetchCallbackIsSendableAndMapsWithoutTheMainActor` opens
  `Sources/OperatorApp/ForegroundRemindersService.swift` relative to `#filePath`
  — a path that exists only in the scratch package, not the on-device bundle.
  Made it `throw XCTSkip` when the source isn't on disk (still asserts under its
  run.sh, where source is present: reminders run.sh = 17 tests, 0 skipped). This
  is the 1 skip in the sim run.
- **`SpotifyLoopbackSetupTests` flaked on the Simulator under load.** It stands
  up a real 127.0.0.1 loopback HTTP server; its `waitUntil` allowed only 1s,
  which the round trip lost to scheduling when all 341 tests ran at once.
  Raised the ceiling to 3s (a passing run still returns in ~7ms). Green on
  macOS run.sh (6/6) and on the sim across three full runs.

## Per-item verification (green this session)

Numbers are from re-running each check this session, not carried over.

**Item 1 — open website → back to chat: FIXED + proven on-sim.**
Root cause (prior finding): both in-app browser openers presented
`SFSafariViewController` with no delegate, so "Done" was dead and the browser
covered chat forever. This session DRY'd the fix behind one seam —
`SFSafariViewController.operatorBrowser(url:)` in `SystemAppHandoffOpener.swift`,
which always wires the shared `SafariReturnDelegate`; both openers
(`SystemAppHandoffOpener`, `InAppMediaOpener`) now build through it. Regression
guard `testOperatorBrowserAlwaysWiresTheReturnDelegateSoDoneReturnsToChat`
(asserts the factory wires the delegate, then that the delegate actually
dismisses a presented controller) **passes on the Simulator** (0.27s). A full
open-real-site→tap-Done→assert-chat XCUITest would need a `bundle.ui-testing`
target; the unit-level proof plus the single shared seam cover the regression.

**Item 2 — Drive/Spotify tolerant input: TESTED (was already correct).**
The native validator only trims/caps; it never rejected spaces or punctuation.
Added 4 tests in `DirectAccountReaderTests`: multi-word Drive query survives,
apostrophe/backslash are escaped (not rejected), Spotify multi-word round-trips
losslessly, whitespace-only is refused without reaching the network. Green via
`connections/read/run.sh` (28 tests) and on-sim.

**Also fixed — dead Google Tasks coverage.** The 6 `testGoogleTasks*` methods
sat inside the `GmailFixtureTransport` actor, not the XCTestCase class, so XCTest
never ran them. Moved them into the class; `connections/read` went 22 → 28 tests,
all green.

**Item 3 — recovery / token refresh: mechanism green this session.**
`connections/auth/run.sh` = 22/22, `connections/notion/run.sh` = 19/19. The
refresh *logic* is unit-covered for every provider including the two the plan
flagged: Slack (`testSlackRefreshAcceptsOnlyUserTokensAtResponseRoot`) and
Notion (`testExpiredRPCTokenDiscoversAndRefreshesBeforeInitialize` + 4 more).
What is still genuinely live-only: refresh against a *real* expired token, a
true network-drop retry, and recovery of an interrupted write — these need the
live sim/accounts and are the owner's to exercise.

**Item 5 — write actions: owner-gating green this session.**
`connections/write/run.sh` = 9/9, `connections/confirmation/run.sh` = 6/6,
`approval-visibility/run.sh` = static wiring PASS (notes real-Simulator
visibility still required). Every write is gated by an on-phone owner-confirm;
the agent can't fire silently. GATE unchanged: a real send/edit, and any
agent-driven test that spends the owner's own ChatGPT/OpenAI account, waits for
explicit owner OK.

**Item 4 — Weather: out of scope** (Apple Developer enrollment; owner aware).

## Environment / cost notes
- No money spent. No paid API was called. The only install was `xcodegen`
  (Homebrew, local dev tool, reversible).
- The live "Operator iPhone 14 Pro" sim (49A153C3…, holds the owner's OAuth
  sessions) was never targeted; all sim runs used a throwaway iPhone 16 Pro.

## How to reproduce
- Cheap per-area loops (macOS, no sim): `sh ios/OperatorApp/Tests/<area>/run.sh`.
- Full app test target (throwaway sim): the `xcodebuild test` line above. Fresh
  DerivedData in a scratch dir; `CODE_SIGNING_ALLOWED=NO` (sim signing is
  ad-hoc).

---

# Live-account verification — 2026-09-12

The owner authorized (this session) spending on their own ChatGPT account and
real irreversible sends **to safe recipients only** (self / Sinchana / wife).
That unblocked the items previously marked "live-only". Below is what ran
against the owner's **real connected accounts** on the live sim
("Operator iPhone 14 Pro", `49A153C3-…`). **Cost: $0** — every check uses
`DirectAccountReader` / `DirectAccountWriter`, which call the providers over
HTTPS directly with the Keychain OAuth tokens. No LLM / chat turn is involved,
so nothing bills the ChatGPT account. All sends were to the owner themselves and
cleaned up.

## The live harness (gated, safe by default)
- New file `ios/OperatorApp/Tests/connections/live/LiveConnectorTests.swift`:
  `LiveConnectorReadTests` (5 reads) + `LiveConnectorWriteTests` (6 writes).
  Each class `XCTSkipUnless(OPERATOR_LIVE=="1")` in `setUp`, so the **default**
  `OperatorApp` scheme skips them all and the normal suite stays green and never
  touches an account.
- New scheme `OperatorAppLive` (in `ios/project.yml`) sets `OPERATOR_LIVE=1`.
  Only this scheme runs the live tests. Never run the whole suite under it —
  select the live class with `-only-testing`.
- The harness reuses the exact bearer the app uses:
  `NativeAccountSetupCoordinator(bundle:.main, presenter:…).accessToken(provider)`
  → real bundle registrations + Keychain (`service app.operator.ios.oauth`) +
  auto-refresh. Installing the test host is an **upgrade install** (no erase),
  so the owner's OAuth tokens survive; no re-login needed.
- Gate proof (throwaway sim, default scheme): `-only-testing` both live classes
  → **Executed 11 tests, 11 skipped, 0 failures — TEST SUCCEEDED**. So the live
  tests are inert unless deliberately run.

## Live READS — all 5 providers, real data (`-scheme OperatorAppLive`, live sim)
`-only-testing:OperatorAppTests/LiveConnectorReadTests` →
**Executed 5 tests, 0 failures — TEST SUCCEEDED** (2.19s).

```
LIVE-READ gmailMessages     count=3  nextCursor=true
LIVE-READ googleDriveFiles  count=0  nextCursor=false
LIVE-READ outlookInbox      count=0  nextCursor=false
LIVE-READ slackChannels     count=4  nextCursor=false
LIVE-READ spotifySearch     count=5  nextCursor=true
```
No `notConnected` skips — every provider's Keychain token was valid (or
auto-refreshed) and returned valid JSON. Gmail/Slack/Spotify returned real rows;
Drive/Outlook returned a valid empty page (nothing matched the probe query),
which the write round-trip below then proves non-empty.

## Live WRITES — self-targeted, create → verify → delete
`-only-testing:OperatorAppTests/LiveConnectorWriteTests` →
**Executed 6 tests, 1 skipped, 0 failures — TEST SUCCEEDED** (6.28s).

```
LIVE-WRITE googleCalendarCreateEvent id=on3mf2tr29mhg4jdcfg0bannhc verified=1 cleaned=true
LIVE-WRITE googleDriveCreateTextFile id=144qGiRC2VI2-V2exXbH-HpQqdu-gM87E  verified=1 cleaned=true
LIVE-WRITE outlookCreateDraft       id=AQMkADAw…                            cleaned=true
LIVE-WRITE outlookSendMail          accepted to ssdear@gmail.com  (REAL SEND, to self)
LIVE-WRITE slackPostMessage         channel=D0BK8RHK6KW ts=1789239684.209859  cleaned=true (REAL post to own DM)
```
- **Google Calendar / Drive:** created a real object, re-read it back through
  `DirectAccountReader` (`verified=1` = the created item was findable), then
  deleted it. This is a full write→read→cleanup round-trip on the live account.
- **Outlook draft:** created in the owner's mailbox, then deleted.
- **Outlook send mail (irreversible):** a real message left the owner's Outlook
  and was accepted for delivery to the owner's own Gmail (`ssdear@gmail.com`).
  Left in place (self-inbox); subject/body marked "Operator live test, safe to
  delete".
- **Slack post (irreversible):** discovered the owner's own DM channel
  (`auth.test` → `conversations.open` with the owner's user id), posted a real
  message, then deleted it (`chat.delete`).
- **Spotify start-playback:** skipped — audible/intrusive and needs an active
  device; left for a manual owner run. Its write logic is unit-covered in
  `DirectAccountWriterTests`.

The `[embedded-runtime] launch failed` / `app-handoff catalog unavailable` lines
in the write log are the XCTest host trying to boot the embedded Node runtime and
handoff catalog — unrelated to the connectors, which never use the runtime. All
tests still passed.

## What this closes on the goal
- **Item 3 (sign-in persists + token refresh), all 5 providers — LIVE.** Every
  read/write above went through `coordinator.accessToken(provider)`, which
  auto-refreshes on expiry. Combined with the prior relaunch-log capture
  (Google/Outlook/Spotify `token refreshed`; Slack connected; Notion
  `notion-renewal outcome=success`), refresh + persistence is proven live for
  all five.
- **Item 2 (Drive tolerant input) — LIVE.** The Drive create+search round-trip
  ran against the real account (`verified=1`), on top of the existing
  tolerant-input unit tests.
- **Item 5 (write actions: send / edit / playback) — LIVE.** Real create/send/
  post proven on Google Calendar, Drive, Outlook (draft + real send), Slack
  (real DM post). Playback left for a manual owner run (intrusive).

## Still open (live, lower priority)
- True **network-drop retry** and **interrupted-write resume** — recovery
  edge-cases at the gateway/runtime layer, not the connector-HTTPS layer proven
  here. Interrupted ordinary read was live-PASS in the prior session.
- Optional full item-1 XCUITest (needs a `bundle.ui-testing` target); item-1 fix
  already landed with an on-sim regression guard.

## How to reproduce the live runs
```
LIVE=49A153C3-BA69-468F-BD21-D827A84E6F07   # the owner's connected sim
# reads:
xcodebuild test -project ios/Operator.xcodeproj -scheme OperatorAppLive \
  -destination "platform=iOS Simulator,id=$LIVE" \
  -only-testing:OperatorAppTests/LiveConnectorReadTests
# writes (real sends to self, self-cleanup):
xcodebuild test -project ios/Operator.xcodeproj -scheme OperatorAppLive \
  -destination "platform=iOS Simulator,id=$LIVE" \
  -only-testing:OperatorAppTests/LiveConnectorWriteTests
```
Install is an upgrade (no `simctl erase`), so the owner's OAuth state is
preserved across the run.

## Recovery: network-drop retry + interrupted-request resume — the real design, and green proof

Investigating the code (read-only sweep, 2026-09-12) changed how these two items
should be tested. **They are not connector-layer concerns and do not need live
accounts.**

**Finding 1 — the connector HTTPS layer deliberately does NOT retry.**
- Writes never retry, by design: `DirectAccountWriter.swift:114-116` ("This
  method never retries"); a transport failure becomes
  `AccountWriteError.outcomeUnknownNotSafeToRetry` (`:98`, thrown `:162-168`).
  This is a safety feature — a write may already have landed on the provider, so
  silently re-sending could double-post/double-send. Correct behaviour, not a gap.
- Reads are single-attempt too; `429` is surfaced as `.rateLimited(retryAfter)`
  (`DirectAccountReader.swift:51`) for the caller to honour, not auto-slept.
So "auto-retry the connector call" is intentionally absent. Retrying an
irreversible send under uncertainty is the bug; not-retrying is the fix.

**Finding 2 — retry / reconnect / resume live at the chat-gateway layer**, which
is fully decoupled from the paid LLM path (protocols `ChatGateway`,
`GatewayTransport`), so it is exercised deterministically with injected fakes at
**$0** — a stronger, repeatable proof than physically dropping the sim's radio
mid-request. The mechanism:
- Reconnect loop with 1s backoff: `ChatSessionModel.recoverWhileForeground()`
  (`ChatSessionModel.swift:291-332`).
- Outbox queue-drain; a failed delivery returns the entry to the queue unchanged
  and re-triggers recovery: `flushOutbox()` (`:239-276`).
- **Interrupted-request resume without double-charge:** each send mints an
  idempotency key (`send()` `:170-175`); on reconnect the gateway first looks for
  the exact saved reply before re-sending — `LocalOpenClawChatGateway.deliver()`
  → `connection.recoverReply(runID: entry.idempotencyKey)`
  (`LocalOpenClawChatGateway.swift:135-144`); a mid-flight native recovery throws
  `.recoveryPending` and keeps the entry retryable rather than failing it.
- Background/suspend: the queued entry survives in persistence and is re-driven
  on foreground.

**Green this session ($0, deterministic):**
- App target (throwaway sim), `-only-testing` the two reconnect/resume suites
  `LocalOpenClawChatGatewayTests` + `ChatSessionModelTests` →
  **Executed 37 tests, 0 failures — TEST SUCCEEDED** (2.8s). These assert exactly:
  reconnect-then-drain-once, no-resend-while-active-delivery, saved-completion
  recovered before re-send, native-recovery-pending stays retryable, terminal
  outcomes don't duplicate the send, offline keeps the message queued without
  inventing a reply.
- `OperatorCore` package (`swift test`, macOS) → **Executed 82 tests, 0 failures**
  — includes `OpenClawGatewayConnectionTests` (connect/reconnect, pairing-retry),
  `OpenClawGatewayConnectionConcurrentRequestTests` (request queue serialize /
  cancel / disconnect-releases-waiters), `URLSessionGatewayTransportKeepaliveTests`
  (socket writable after ping cadence, wire order preserved, close-then-open drops
  old frames), `ConversationStoreTests` (sending entry returns to waiting after
  relaunch **without changing its key**; caller message identity survives
  persistence + retry), and `RuntimeLifecycleMachineTests` (failed runtime retries
  on next foreground; cold-launch → background snapshot → foreground restore).

**Live corroboration already captured:** the prior-session relaunch on the live
sim logged `gateway restored` + node re-paired with all 26 commands after a
terminate — a real reconnect + re-pair on the owner's device, matching the
deterministic reconnect path above.

**What remains genuinely paid and is intentionally left un-run:** a true
end-to-end run that sends a real chat turn through the embedded Node runtime to
the LLM and drops the socket mid-stream. It would cost money and is *flakier*
(timing the drop) while proving only that the real runtime emits `chat.history`
the way the fakes already model. The deterministic suites above are the better
evidence; this end-to-end variant is available on request but not worth the spend.

## Full-path end-to-end proof through the real LLM — 2026-09-12

This is the one thing every earlier live test deliberately skipped: the whole
chain a real user hits, driven through the actual chat UI, with the on-device
LLM (not the harness) deciding to call the connector.

**How it was run.** A gated XCUITest (`ChatEndToEndUITests`, target
`OperatorAppUITests`, scheme `OperatorAppE2E` sets `OPERATOR_E2E=1`) launches the
real app on the **live sim** (49A153C3, real OAuth + real ChatGPT auth), clears
any draft, types "Check my Gmail inbox and tell me the sender and subject of my
single most recent email.", taps Send, and waits for a *genuinely new* assistant
bubble (it snapshots existing bubbles first, so a stale reply can't false-pass).
Paid: one chat turn on the owner's ChatGPT device-code account **ssdear@gmail.com**
(personal, pre-approved, recorded in the `connector-testing-consent` memory).

**Result: TEST SUCCEEDED (48.8s).** The reply captured from the chat bubble:
`Sender: Instagram notification@priority.instagram.com` — real inbox content.

**Ground truth from os_log (live sim, process 73067), in order within the turn:**
```
[chat] staged input id=E4D250A6… characters=87            <- my prompt, 87 chars, no stale draft
[gateway] sent chat request id=80a17cc9…                  <- sent to the LLM
[chat-timing] phase=accepted … outcome=none               <- LLM turn started
[location-node] handling command=connections.read id=a2b677ed…   <- LLM CHOSE to read Gmail
[location-node] sent result id=a2b677ed…                  <- connector returned inbox data
[chat-timing] phase=first-text … / phase=terminal outcome=reply
[chat] reply persisted for id=E4D250A6…                   <- reply is for MY message id
```
The `connections.read` command handled mid-turn is the definitive proof the
connector fired *because the LLM decided to*, not because a harness called it
directly. (The `[account-read]` line from `DirectAccountReader` does NOT appear —
the runtime/LLM path uses the native-node command surface `connections.read`
instead; both are real, and `connections.read` is the one a real "check my email"
actually exercises. The node surface advertised all 26 commands incl.
`connections.read/write/describe`.) `modelConfigured=true` confirmed the model was
signed in. The live sim's auth survived (upgrade-install only).

**A real bug this uncovered and fixed (project.yml).** Every build I installed
before this was silently missing the Copy Bundle Resources phase for the
OperatorApp target, so the embedded Node runtime (`runtime/entry.mjs`), the asset
catalog, and the handoff JSON never made it into the app — the runtime failed to
launch (`[embedded-runtime] launch failed … code=0` → `chat connection gate
closed`) and chat/LLM could not run at all. Root cause: **XcodeGen 2.46 silently
drops a top-level `resources:` block for this target** (parsed by `xcodegen dump`
but never emitted as a build phase; git `dfe0376` had 3 Resources phases, my
regens had 0). Fix: declare the resources under the target's `sources:` block
(asset catalog + JSON auto-classify; the runtime folder with
`type: folder, buildPhase: resources`) — that code path emits the phase.
After the fix the built `.app` contains `runtime/entry.mjs` (695B) + subdirs and
`Assets.car` (63KB), the runtime boots (`[embedded-runtime] ready`), and the
end-to-end proof above passes. The connector *reads/writes proven earlier stay
valid regardless*, because `DirectAccountReader/Writer` talk HTTPS directly and
never touch the Node runtime.

**Free regression guard:** `ChatEndToEndUITests.testAppLaunchesAndChatComposerIsReachable`
(ungated, no LLM/accounts) launches the app and asserts the chat composer is
reachable — green on the throwaway sim (19.5s). If the runtime/resources break
again, this catches it at $0.

### Write path end-to-end through the real LLM, incl. the owner-approval gate — 2026-09-12

Same harness (`ChatEndToEndUITests.testSelfEmailSendRoutesThroughLLMOwnerApproval-
AndSends`, scheme `OperatorAppE2E`), live sim. Typed into the real chat UI:
"Send an email to ssdear@gmail.com with the subject 'Operator E2E write test' and
the body 'End-to-end write-path test — safe to ignore.'" — a real send to the
owner's OWN address (pre-authorized safe recipient). Paid: one chat turn on
ssdear@gmail.com's ChatGPT account (authorized by the owner for this run).

**Result: TEST SUCCEEDED (61.7s).** Reply captured from chat: `Email sent successfully.`
A real email actually sent (HTTP 202) from the connected Outlook account to
ssdear@gmail.com.

**Ground truth from os_log (live sim), in order within the turn:**
```
[chat] staged input id=E6F7353E… characters=136                 <- my send prompt
[location-node] handling command=connections.write id=88f36d2d…  <- LLM CHOSE to write
   -- on-phone owner-approval alert shown here (see below); test tapped Allow --
[account-write] input operation=outlookSendMail field_count=3 content_bytes=85
[account-write] request provider=microsoftOutlook operation=outlookSendMail method=POST request_bytes=226
[account-write] response operation=outlookSendMail status=202 response_bytes=0   <- real send accepted
[account-write] complete operation=outlookSendMail
[chat-timing] phase=terminal … outcome=reply
[chat] reply persisted for id=E6F7353E…                          <- reply for MY message id
```

**The owner-gate provably gates.** The test captured the on-phone approval alert
before any send fired:
- title: `Allow account action?`
- preview: `Send email to ssdear@gmail.com  Subject: Operator E2E write test  Body: End-to-end write-path test — safe to ignore.`

The `[account-write] request … status=202` (the real send) appears in the log
ONLY after the test tapped **Allow** — i.e. no send happens without the owner
approving the exact previewed action. This is a UIKit `UIAlertController`
("Allow account action?" / buttons "Allow" / "Cancel") from
`SystemAccountWriteConfirmationPresenter`; XCUITest reaches it via `app.alerts`.

**Notes / scope.** There is no Gmail *send* op — Gmail is read-only; the email
send goes through `outlookSendMail` (Outlook connected on the live sim). All six
write ops were confirmed at the connector layer (free, self-targeted, auto-
cleaned) on the live sim the same day: googleCalendarCreateEvent,
googleDriveCreateTextFile, outlookCreateDraft, outlookSendMail, slackPostMessage
all **passed**; spotifyStartPlayback skipped (intrusive, manual). So both a
read and a write now have full LLM→connector→chat proof, and the write also
proves the owner-approval gate.

---

## Notion live read + write, and Spotify read/resolve — 2026-09-12

Connector-layer live proofs (FREE — no LLM turn; only the connector HTTPS calls
run) on the live sim (Operator iPhone 14 Pro, `49A153C3-…`), via the
`OperatorAppLive` scheme (`OPERATOR_LIVE=1`). New tests:
`ios/OperatorApp/Tests/connections/live/LiveNotionSpotifyTests.swift`.

### Notion — READ proven
`LiveNotionTests.testNotionListToolsAndSearch` **passed**. Through the app's
`NotionMCPClient` (stored Keychain token, service `app.operator.ios.notion`) it
listed **43 tools** and ran a real `notion-search` that returned the owner's live
workspace (e.g. "PPV Command Center 2026", "Action Items", "sinchana", …).

### Notion — WRITE proven (reversible, zero litter)
`LiveNotionTests.testNotionAppendVerifyRemove` **passed**. Ground-truth LIVE
lines:
```
LIVE-NOTION-WRITE fixture=3dae6004-5e9f-8131-a66b-ec4c2919ebcb inserted=true
LIVE-NOTION-WRITE inserted=true removed=true
```
It appends a uniquely-marked line to a reused fixture page via
`notion-update-page insert_content`, fetches it back and confirms the mark
landed (`inserted=true`), then removes the line via `update_content` and fetches
again to confirm it is gone (`removed=true`). Net change to the workspace: none.
A first attempt created a fresh page and proved create+fetch directly (page id
`3dae6004-…`, title "Operator Live Connector Test …", verified=true); that page
was then repurposed as the fixture ("Operator Live Test Fixture — safe to
delete"), fetched afterward to confirm it holds only the fixture note.

**Connector limitation found:** the Operator Notion connector can
create/read/update pages but has **no delete/archive path** — no MCP tool
exposes one, and the MCP OAuth token is rejected **401** by `api.notion.com`
REST (`PATCH …/pages/{id} {"archived":true}` → 401). Hence the reversible
append/remove design instead of create-then-delete. One clearly-labelled fixture
page persists in the workspace by design; delete it from Notion manually if
unwanted.

### Spotify — search + track-URI resolve proven; playback needs an active device
`LiveSpotifyPlaybackTests.testSpotifyDetectDeviceAndResolveTrack` **passed**:
```
LIVE-SPOTIFY playbackState count=0 payload=[]
LIVE-SPOTIFY resolvedTrackURI=spotify:track:4aK4LNijbD7kkCg54UoIij activeDevice=<none>
```
The search read returns tracks; the `.spotifySearch` sanitizer keeps `id` (the
22-char track id) but **not** `uri`, so the playable URI is reconstructed as
`spotify:track:<id>`. `.spotifyPlayback` (GET /v1/me/player) returns 204 → empty
when nothing is playing, so `count=0` = **no active Spotify device**.

`LiveSpotifyPlaybackTests.testSpotifyStartPlaybackOnActiveDevice` starts real
playback (`PUT /v1/me/player/play`, body `{"uris":[trackURI]}`, via the app's
`DirectAccountWriter.writeAfterOwnerConfirmation(.spotifyStartPlayback…)`), but
**skips** when `count==0`. **Precondition (owner-only):** open Spotify on a
device and press play then pause (Spotify **Premium** required) so Spotify Connect
has an active device; then this test plays a track and asserts the
`.spotifyPlaybackStarted` receipt. Playback is fundamentally impossible when no
Spotify client is running anywhere (Connect has zero devices).

### Spotify — PLAYBACK proven (2026-09-12, later)
Once the owner started a track (giving Spotify Connect an active device),
`LiveSpotifyPlaybackTests.testSpotifyStartPlaybackOnActiveDevice` **passed**:
```
LIVE-SPOTIFY-PLAY trackURI=spotify:track:4aK4LNijbD7kkCg54UoIij device=548901877a38738a667ec2865d20846f30547ac0 receipt=spotifyPlaybackStarted
```
The app read the active device from `.spotifyPlayback`, resolved a real track,
and started it via `DirectAccountWriter.writeAfterOwnerConfirmation(.spotifyStartPlayback…)`
(`PUT /v1/me/player/play`) — audibly changing what was playing on the owner's
device — and got the `.spotifyPlaybackStarted` receipt. **All in-scope Operator
connectors now have live read + write proof.**

### Read endpoints — full coverage (2026-09-12, later)
Completeness audit: of the 10 `AccountReadOperation` cases, 7 already had live
proof (`googleCalendarEvents`, `googleDriveFiles`, `gmailMessages`, `outlookInbox`,
`slackChannels`, `spotifySearch`, `spotifyPlayback`). The remaining 3 are now
proven live on the LIVE sim, all green together:
```
LIVE-READ googleTasks count=1 nextCursor=false
LIVE-READ outlookCalendarEvents count=0 nextCursor=false
LIVE-READ slackHistory channel=C0BK1RZJVPX count=2
Executed 3 tests, with 0 failures — ** TEST SUCCEEDED **
```
Tests: `LiveConnectorReadTests.testGoogleTasksLiveRead`,
`testOutlookCalendarLiveRead`, `testSlackHistoryLiveRead` (the last walks the
listed channels and proves history on the first the app can read).
`outlookCalendarEvents count=0` = the connected mailbox's calendar is genuinely
empty (verified: `GET /me/events` → 200 `value:[]`), not a failure.

**calendarView 1825-day cap (diagnosed, then fixed the test):** the Outlook
calendar read first failed with `AccountReadError.unavailable`. A one-off
diagnostic hit the exact URL and got the real cause — **HTTP 400**
`ErrorInvalidRequest: "…range between the start and end dates is greater than the
allowed range. Maximum number of days: 1825"`. So it was **not** a missing scope
(that returns 403 → `.permissionDenied`) and **not** a connector bug — the test
passed a 15-year window (2020→2035). Fixed the test to a legal window
(2024→2027, ~1096 days); it now returns 200. Note for the product: a caller
requesting a >5-year calendar span will get `.unavailable` from Graph; realistic
ranges are well inside the cap, so the connector is usable as-is.

**Every read (10) and every write (6) Operator connector operation, plus Notion
read+write, now has a live proof on the owner's real accounts.**

---

## 2026-09-15: permissions, first writes, and the first message sent for the owner

All on the iPhone 17, watched by the owner, with the device log alongside.

### Rows that moved

| Connector | Command | Live result |
| --- | --- | --- |
| Contacts | `contacts.search` | **read live** - denied, granted from the in-chat banner, then answered |
| Device | `device.status` | **read live** through the permission gate |
| Messages (composer) | `sms.compose` | **write live** - system sheet presented, owner tapped Send, `outcome=sent` |
| Open apps | `apps.open` | **write live** - YouTube opened inside Operator |
| Messages, sent for you | `sms.send` | **write live** - handed to the shortcut, iMessage arrived, x-callback `success` recorded |

### What the permission layer did on its first live run

Every step visible in the log, none of it reasoned about afterwards:

    contacts.search  -> denied connector=contacts access=read
                     -> (owner taps Allow on the banner)
                     -> granted; published agent tools count=2
    contacts.search  -> ran
    sms.compose      -> denied connector=messages access=write
                     -> granted

The default was truly nothing: on first launch the node published
`count=0` tools and the model was offered none until the owner allowed
one. Republishing on a live socket worked without a reconnect.

### Two defects the run surfaced, both fixed the same session

- **Two verbs for one intent.** The model called `sms.compose`, the
  command it knew, so `sms.send` never ran. The "sent for you" grant now
  decides how a compose goes out (48c15e6); the model's choice of verb no
  longer matters.
- **Stale seeded guidance.** The workspace `AGENTS.md` still said the
  agent had no tool that sends a message, because OpenClaw writes it only
  when missing. The agent believed it and the owner had to prompt twice.
  The section is now refreshed on every start, inside markers (a0a5543).

### How the shortcut gets installed, and what did not work

Only an iCloud share link opened directly installs a shortcut on iOS 18
and 26. Tried and refused, each reproduced on the Simulator:
`shortcuts://import-shortcut` with a signed file on GitHub ("The shortcut
URL provided was invalid" - and the same for a plain README URL, so not
encoding); the same scheme pointed at the iCloud link ("The file isn't in
the correct format"). Unsigned files are refused outright since iOS 15.
The link was produced by sharing the checked-in signed file from the
Shortcuts app on the developer's Mac; sharing it again renews the link.

### Still open, in the order they matter

- **Recipient allowlist for sent-for-you.** The only gate on who a
  silently sent message reaches is the model's judgement and the prose in
  AGENTS.md. A prompt-injected reminder saying "text everyone" has
  nothing in code stopping it. This should land before the feature is
  used for anything but the owner's own number.
- **Cross-service-turn gate** (no sending in a turn that also read
  external content) - prose only.
- **openclaw's own outbound tools** (`web_fetch`, `browser`, `message`)
  are still enabled and ungated; the setup branch also turned on native
  web search. The permission page governs Operator's connectors, not
  these.
- **App switch drops the node.** Returning from Shortcuts shows "Starting
  Operator" while the node reconnects; the x-callback still landed 30s
  later. Harmless today, worth smoothing.
