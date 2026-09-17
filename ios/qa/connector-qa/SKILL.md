---
name: connector-qa
description: Run realistic, repeated QA against every Operator iPhone connector (Gmail, Calendar, Drive, Tasks, Outlook, Slack, Spotify, Notion, WhatsApp, Discord, Canvas, YouTube, Podcasts, Maps, device services) through the real chat and the real ChatGPT model, then judge the results. Use when asked to test, QA, or verify a connector, or after changing connector code.
---

# Connector QA

Drives the real app on the live Simulator through the real model, the way a
user would: prompts in several registers (precise, casual, vague, typo,
indirect, followup, clarify, decline, write), each sent several times across
cold and warm launches. Ground truth is the app log and the persisted chat
store, never the reply alone. Mechanical checks run first; you judge the rest.

Everything lives in `ios/qa/connector-qa/`. Runs are saved under
`saved-results/connector-qa/runs/<runId>/`.

## Cost and account

Every step is one real ChatGPT turn on ssdear@gmail.com (personal account,
approved by the owner on 2026-09-14 for this workflow, no cap). Full pass at
3 repeats is roughly 600 turns. Before a run, state the turn count from
`--dry-run` in your reply. Stop on rate limits (the runner marks them `blocked`).

## Preconditions (check, do not fix silently)

- Simulator `49A153C3-BA69-468F-BD21-D827A84E6F07` ("Operator iPhone 14 Pro")
  has the app installed with ChatGPT signed in and the connectors connected.
  Never erase the Simulator or uninstall the app; that loses the Keychain.
- Every connector under test is **granted on Operator's Permissions page**
  (menu → Permissions; reads and, for write banks, acts). Grants default to
  none, and a connector without a read grant is not even offered to the model,
  so an ungranted bank scores `commands-any` fails that look like the model
  refusing. When the model does reach an ungranted command, the driver taps
  Allow on the in-chat banner, the step is scored `blocked` (`grant-missing`),
  and the next repeat runs with the grant. The driver never accepts a write
  acknowledgement (WhatsApp send stays off) and never turns Read-only on or off.
- Xcode 16.4, `xcodebuild` on PATH. Never pass `CODE_SIGNING_ALLOWED=NO`.
- No other test is driving that Simulator.

## Steps

1. **Unit tests** (seconds, free):
   `node --test ios/qa/connector-qa/tests/*.test.mjs`
2. **Plan** the run and read the turn count:
   `node ios/qa/connector-qa/run.mjs run --connector gmail --repeats 3 --dry-run`
   Use `--connector a,b`, `--scenario id`, `--kind casual,typo` to narrow.
   `run.mjs list` prints every scenario.
3. **Run** (background it; a connector takes 10 to 40 minutes):
   `node ios/qa/connector-qa/run.mjs run --connector gmail --repeats 3 --label gmail`
   Add `--skip-build` when the QA build in `/private/tmp/operator-qa-derived`
   is current. The runner boots the sim, streams the app log, drives batches
   of 8 steps through XCUITest (`ScenarioDriverUITests`), taps Allow/Cancel on
   approval alerts itself, and writes `results.jsonl`, `judge-input.jsonl`
   and a mechanical `report.md`.
   Each batch also snapshots the chat store (`batch-N.conversation.json`), so
   `run.mjs rescore --run <runId>` can redo the mechanical checks offline after
   a check or an `expect` block changes. No model turns are spent.
4. **Read the mechanical report** at `saved-results/connector-qa/runs/<runId>/report.md`.
   `blocked` means the environment, not the connector: sign-in, permission,
   rate limit, driver timeout. Fix the environment and rerun those scenarios.
5. **Judge** every row of `judge-input.jsonl` using `judge/rubric.md`.
   Do this in a fresh subagent that has not seen the run (it must reason
   from the rubric, not from your expectations). It writes `verdicts.jsonl`
   (one `{stepKey, verdict, reason}` per row). A judge can only lower a verdict.
6. **Merge**: `node ios/qa/connector-qa/run.mjs report --run <runId>`.
   The report now carries pass / flaky / fail / blocked per scenario.
   `flaky` is its own verdict: some repeats passed, some failed. Never round it up.
7. **Clean up** every run that included `write` scenarios:
   `node ios/qa/connector-qa/run.mjs cleanup --run <runId>` sweeps the run
   marker from Drive, Calendar, Tasks, Outlook, Slack. Notion pages must be
   removed by hand (no delete tool). Record what was swept in the reply.
8. **Report** in `saved-results/connector-qa/`: link the run directory, list
   fails and flakies with the reason line, and name the account and turn count.

## Adding scenarios

Edit the bank in `ios/qa/connector-qa/scenarios/<connector>.json` (schema in
`scenarios/README.md`). Every bank needs precise, casual, vague, typo,
indirect, followup and clarify kinds. Write prompts must contain `{marker}`
and target the owner's own accounts only. Run the unit tests; they validate
the banks.

## Reading a failure

Each turn in `report.md` shows the prompt, the reply, the commands and
operations the app ran, statuses and alerts. `results.jsonl` adds the raw log
lines for that window. A `commands-any` fail with a confident reply means the
model answered without the connector (fabrication), or the connector was
never granted so the model was never offered it: check the Permissions page
before blaming the model. A `grant-missing` block means the model reached a
command the owner had not allowed. A `status-2xx` fail is the provider or
token. A `reply-present` fail with `sawWorking` true is a runtime hang; check
`batch-N.xcodebuild.log` and the screenshot in the xcresult. An `app-alive`
fail is a crash: the report is in `~/Library/Logs/DiagnosticReports`, and
the Sep 15 runs' `Intl.Segmenter` crashes are fixed by
`Runtime/native-node/compat/intl/segmenter.mjs`.
