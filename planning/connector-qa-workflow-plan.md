# Connector QA workflow plan

Date: 2026-09-14. Branch `qa/connector-workflow`. Owner approved: real ChatGPT
turns on ssdear@gmail.com, no hard cap; writes auto-approved by the driver,
self-targeted only, cleaned up after.

## Why the last attempt failed (owner's words)

Prompts were "testing"-shaped, not user-shaped, and every feature was tried
once. So it missed the two things that break on real users: phrasing the
model has not seen, and behaviour that only holds under one condition.

## Shape of the fix

```text
scenario banks (per connector, user-shaped prompts, expected outcome)
        |
        v
run.mjs ----> boots the live Simulator, starts `log stream`
        |
        +--> for each scenario x N repeats x condition (cold / warm / follow-up)
        |        |
        |        v
        |    ScenarioDriverUITests (XCUITest, real app, real model)
        |        types the prompt, taps Send, taps Allow on every
        |        approval alert, waits for the reply, prints QA-STEP lines
        |        |
        |        v
        |    collect: reply text from conversation.json,
        |             command + status lines from the log,
        |             alerts seen, elapsed time
        |
        +--> mechanical checks (commands fired? forbidden ones didn't?
        |     status 2xx? reply not a failure phrase? approval seen?)
        |
        v
judge-input.jsonl ---> the operator LLM (Codex / Claude Code) applies
        |               judge/rubric.md to every run and writes verdicts
        v
report.md  (pass / flaky / fail / blocked per connector x scenario,
            with the log line and reply that decided it)
        |
        v
cleanup (LiveConnectorCleanupTests sweeps the run marker)
```

## Definition of done, observable

1. `node ios/qa/connector-qa/run.mjs --connector gmail --repeats 2` runs
   against the live Simulator without a person touching it, and leaves
   `saved-results/connector-qa/runs/<id>/{results.jsonl,judge-input.jsonl,report.md}`.
2. A scenario that fires the wrong command, gets a non-2xx, or produces a
   failure-phrase reply is marked fail by the mechanical check alone, before any
   LLM judges it.
3. A scenario that passes 1 of 3 repeats is reported `flaky`, never `pass`.
4. Every connector in the inventory has a scenario bank with at least: a
   casual phrasing, a vague phrasing, a typo'd phrasing, an indirect ask, a
   follow-up, a should-clarify, and a should-decline.
5. `SKILL.md` lets a fresh Codex or Claude Code session run the whole loop and
   fill the report, with no knowledge from this session.

## Steps

1. Scenario schema and banks (`ios/qa/connector-qa/scenarios/`).
2. `ScenarioDriverUITests.swift` + `OperatorAppQA` scheme (`OPERATOR_QA=1`).
3. `run.mjs` + `lib/` (sim, log capture, conversation extraction, checks, report).
4. `judge/rubric.md` and `SKILL.md`; register for Claude Code (`.claude/skills`)
   and Codex (`AGENTS.md`).
5. Prove it: free smoke run (no LLM), then one paid run on Gmail reads with 2
   repeats, then one write scenario with cleanup.
6. Fresh judge agent attacks the plan and the result; fix what it finds.

## Risks named up front

- The driver depends on accessibility labels (`chat-composer`, `Send`,
  `Operator, …`, alert titles). A UI change breaks it loudly, not silently:
  every step asserts the element exists.
- Simulator on another Space breaks alert taps (Sep 13 gotcha). XCUITest taps
  in-process alerts, so this should not apply; verify on the first write.
- Permission prompts (Reminders, Contacts, Photos, Location) are Springboard
  alerts; handled through the springboard app, not `app.alerts`.
- Rate limits on the ChatGPT account stop a run; the runner records `blocked`
  and stops instead of marking fails.
- Notion prompts once per tool call; a "create page" is 3 alerts. Driver loops.
