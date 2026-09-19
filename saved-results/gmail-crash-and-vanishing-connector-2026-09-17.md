# Gmail crash, then "the Gmail connector disappeared" (2026-09-17)

What this is for: three linked failures seen on the QA Simulator in one night,
what caused each, and what was changed. Read this if Gmail "vanishes", the app
crashes on a reply, or every message fails after a reinstall.

## 1. App crashed while reading Gmail

- Input: a Gmail read whose reply text had to be split into characters.
- Expected a reply; got a crash (`JSSegments::Create`, null pointer) in the
  crash report `~/Library/Logs/DiagnosticReports/Operator-*.ips`.
- Step that went wrong: the phone's copy of Node has no text-splitting data,
  so `Intl.Segmenter` crashes. The repo has a JS stand-in
  (`ios/Runtime/native-node/compat/intl/segmenter.mjs`), but the built copy of
  the runtime in `ios/build/native-node/runtime` (ignored by git, built per
  machine) was from Sep 9 and did not contain it.
- Fix: rebuilt that copy from openclaw 2026.9.1:
  `node ios/Runtime/native-node/package/run.mjs <openclaw package> <new dir>`.
  Added a build step that fails the build when the copy is out of date
  (`ios/Runtime/native-node/package/check-staged-runtime.sh`, commits c6cdcac,
  2ed1481). Verified: passes on the new copy, fails on the old one.

## 2. Every message failed right after a reinstall

- Input: I reinstalled the app while a task was running.
- What happened: on restart OpenClaw finishes the cut-off task first
  ("[System] Your previous turn was interrupted by a gateway restart").
  Messages sent during that get an empty answer; the app shows "No readable
  result was received."
- It cleared by itself once the recovery turn ended. NOT fixed: the app still
  shows a failure and drops the real reply in that window.
- Rule for testing: do not install over the app while a task is running.

## 3. Model kept saying the Gmail connector was gone (it was not)

- Input: any Gmail request after that restart, for about two hours.
- Expected a `nodes` call (`connections.read`); got "no Gmail-reading
  connector available".
- Evidence it was a false belief, not a missing tool:
  - OpenClaw's saved record for the turn (`session_nodes.entry_json` →
    `systemPromptReport.tools`) listed 64 tools including `nodes`.
  - No dropped-tool records anywhere in the two databases.
  - Told to call `nodes` anyway, the model did, it worked, and it replied
    "I was wrong when I said it was unavailable" (transcript seq 851-853).
- Step that went wrong: the recovery turn after a restart really does run
  with read-only tools only. In that turn the model wrote "connector
  disappeared". On later turns it trusted that message, and "checked" by
  asking the `openclaw` helper tool, which cannot see the tool list or the
  phone and answered "not configured". Asked to list its tools it even left
  `nodes` out of the list.
- Fix (commit 9f2c285): new section "When a tool seemed to be missing" in
  `ios/Runtime/native-node/package/workspace-guidance.mjs`: call the tool,
  do not trust earlier messages, never ask `openclaw` whether a tool exists.
- Found on the way: this Simulator's `workspace/AGENTS.md` was from Sep 11,
  before any Operator guidance existed, and the refresh code skipped files
  with no Operator section, so this phone had none of the guidance. The
  refresh now appends the section (`gateway/state.mjs`). Verified on the
  Simulator after install: the file has the new section and keeps its
  original text. 21/21 runtime tests pass
  (`node --test $(find tests -name '*.test.mjs')` in `ios/Runtime/native-node`).
- Not yet verified: that the wording prevents the belief after a fresh
  mid-task restart (needs a deliberate restart test).

## Cost

Two short test turns on the owner's personal ChatGPT account
(ssdear@gmail.com), approved 2026-09-14 for connector testing.
