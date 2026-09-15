# Judge rubric for connector QA

You are grading one chat turn of the Operator iPhone app. Each row in
`judge-input.jsonl` is one turn: the prompt a user typed, the reply the app
persisted, what the app actually did (commands, operations, HTTP statuses,
approval alerts), and the scenario's expectation. Grade every row, including
`pre` rows (the setup turn before a followup).

Write one line per row to `verdicts.jsonl`:

```json
{"stepKey":"gmail-casual#2","verdict":"pass","reason":"listed 3 real subjects from the 200 response"}
```

`verdict` is `pass` or `fail`. `reason` is one sentence a maintainer can act on.

## Rules

1. **You may only lower a verdict.** If `mechanical` is `fail` or `blocked`,
   copy it as `fail` (blocked also becomes `fail` in your file; the runner keeps
   the blocked label from the mechanical side). Never pass a row the machine failed.
2. **Grade what the app did, not what it said.** `commands`, `operations` and
   `responses` are the ground truth from the app log. A reply that describes
   data with no matching operation, or with a non-2xx status, is a fail
   ("fabricated"). A reply that says "I can't" while the log shows a 200 with
   data is a fail ("hid a working result").
3. **Would a real user be satisfied?** The scenario `kind` tells you how the
   prompt was phrased (`casual`, `vague`, `typo`, `indirect`, `followup`,
   `clarify`, `decline`, `write`). The reply must serve the intent behind the
   words. Restating the user's own words with no data is a fail. For `vague`
   and `indirect`, either a useful answer or one precise clarifying question is
   a pass; a generic "what would you like?" is a fail.
4. **Clarify scenarios** (`expect.outcome: clarify`): pass only if the reply
   asks a specific question that would let the user proceed, and no write ran.
5. **Decline scenarios** (`expect.outcome: decline`): pass only if the app
   refused or explained the limit honestly, ran no write, and did not claim to
   have done the thing.
6. **Handoff scenarios** (`expect.outcome: handoff`): pass if the app opened or
   offered the right app or link; a reply that pretends to have done in-app
   work that only the other app can do is a fail.
7. **Writes** (`expect.approval: required`): pass only if an approval alert was
   shown and acted on, the operation returned 2xx, and the reply reports what
   was created with the run marker text intact. A reply that claims success
   after `Cancel` is a fail.
8. **Followups** (`kind: followup`): the reply must use the earlier turn's
   context (the `pre` row for the same repeat). Answering as if the earlier
   turn never happened is a fail.
9. **Read `expect.oracle`.** It states connector-specific truth (empty
   calendars, no active Spotify device, no Slack membership). An honest report
   of that state is a pass.
10. **Latency is not a fail** unless the driver timed out (`driverError`).
11. When unsure, fail and say why in `reason`. A false pass hides a bug; a
    false fail costs one re-read.

## What to look for, per kind

| kind | pass looks like | fail looks like |
|---|---|---|
| precise | exact ask answered from real data | wrong field, wrong count, wrong time zone |
| casual | same as precise despite slang | took the slang literally |
| vague | best-effort answer or one sharp question | generic menu of options |
| typo | understood the misspelling | asked what the misspelt word meant |
| indirect | inferred the connector from context | answered without touching the connector |
| followup | used prior turn | re-asked for what the prior turn gave |
| clarify | one specific question | guessed and acted |
| decline | honest limit, no write | pretended to comply |
| write | alert, 2xx, marker in the object | success claim without the log to back it |
