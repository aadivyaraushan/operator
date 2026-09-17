# Answer the model's questions

Written 2026-09-16, before implementation. Found while asking why a run
was "taking forever": the model had called OpenClaw's built-in `ask_user`
tool ("What should I send in the Aadivya and Arnav group chat?", three
options, 15-minute timeout) and Operator has no way to show or answer it.
The run sat until the timeout. The phone's transcript holds two earlier
`ask_user` calls, both ended by a force-quit. The "fade everything" hang
in the workspace guidance is the same failure from the other side.

## Decision

Operator becomes a question client of the gateway, the way it is already
an approval client. No node command, no runtime patch, no change to the
tool: OpenClaw 2026.9.1 has the whole protocol and the model is already
blocked on `question.waitAnswer`; the phone just never answers.

Questions render in the thread as a card, per DESIGN.md (sheets retired,
asks are agent messages with the preview inline), carrying the `Waiting
for user` mark. On answer the card collapses to what was chosen and the
run continues. Off screen, with a reply kept alive, the question goes
out as a notification whose actions are the options, like the WhatsApp
send confirmation; free text falls back to opening the app.

The model's `timeoutSeconds` is honoured: OpenClaw expires the question
itself and the model then says it is waiting. Operator does not cancel
on the model's behalf, except for `isSecret` questions, which it cannot
show and cancels at once with that reason.

## What the gateway provides (2026.9.1, read from the bundle)

- Events on every connected client: `question.requested` (the record)
  and `question.resolved` (`{id, status: answered, answers} | cancelled
  | expired`).
- Record: `id` (`ask_<32 hex>`), `questions[1..3]`, each `questionId`
  (`^[a-z][a-z0-9_]*$`), `header` (<=12 chars), `question`, `options`
  (0 or 2..4 of `{label, description?}`), `multiSelect?`, `isOther?`,
  `isSecret?`; `createdAtMs`, `expiresAtMs`, `status`, `sessionKey?`,
  `runId?`, and when terminal `answers?`, `resolvedBy?`.
- `question.list` / `question.get` for replay after a reconnect.
- `question.resolve` with `{id, answers: {answers: {[questionId]:
  [values]}}}` or `{id, cancel: true}`; result `{status: answered,
  answers} | {status: cancelled}`. Scope `operator.questions`, which the
  app's `operator.admin` covers.
- Default timeout 900 s.

## Pieces, in order, each its own commit

1. OperatorCore: `GatewayQuestions.swift` (record, question, option,
   resolved event, answers), the two events in `decodeInbound`, and
   `listQuestions()`, `answerQuestion(id:answers:)`,
   `cancelQuestion(id:)` on the connection, each checking the result the
   way `resolveApproval` does. Tests in the gateway suite.
2. `ChatSessionModel.questions`: fed by the event loop beside
   `approvals`, replayed with `question.list` on every foreground
   subscription, dropped on `question.resolved` from anyone, on expiry,
   and on a run's terminal event. `answer(_:)` and `skip(_:)`.
3. `QuestionCard` in the thread: header, question, one button per
   option with its description, a field when `isOther`, toggles when
   `multiSelect`, Skip. Collapses to "You answered: …". Live check on
   the phone with the exact prompt that hung.
4. Notification path for questions that arrive while a reply is kept
   alive off screen; the tap resolves through the same model call.
5. connector-qa: a mechanical check that every `question.requested` in
   a run's log has a matching `question.resolved`, not a restart.

## Not in scope

Secret questions (the gateway says "not supported yet" itself).
Multiple questions in one request render as one card per question; the
answer is sent once all are answered.
