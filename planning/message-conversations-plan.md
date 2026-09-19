# Message follow-through in the main chat

## Intended behavior

“Ask Aadivya about CS374 homework and dinner plans” starts one task with two
independently tracked questions. When Messages automatic sending is enabled,
Operator sends the first message and follows up automatically when it is
confident a reply leaves a question unanswered. Homework alone does not resolve
dinner. Completion requires an evidenced answer to every question.

## Implementation

- Task cards live inline in the main chat. No separate Conversations window or
  per-task automatic-mode selection. Cards show answers, remaining questions,
  progress, Pause, Resume and Cancel. Missing permissions leave a proposed task
  ready to start from its card.
- Every send checks current Messages Read, Act, sent-for-you and read-only
  permissions. Starting a task is an owner-requested action; received messages
  cannot authorize new recipients or scope.
- Replies are matched to an exact international phone number or email. The model
  reports question answers with message IDs and exact evidence quotations plus
  an optional agent-written followupMessage. No question-to-message template is used;
  refusal or ambiguous context requires owner attention.
- There is no ten-minute delay between follow-ups. A 60-second quiet period, reset by every new message,
  lets multipart incoming replies arrive before review and sending. The agent
  waits when the recipient indicates they are still checking or composing. The agent writes any next reply itself, or chooses to wait. There is no fixed
  follow-up count. Tasks retain outgoing reply history and a 24-hour lifetime.
  Silence alone does not trigger a review.
- Native durable reservations prevent duplicate sends; uncertain/interrupted
  sends never automatically retry. New replies invalidate pending drafts and
  stale model reviews. Failed reviews have three leased attempts per revision.
- Incoming messages are retained during suspension. AI review resumes while
  Operator is open and chat is idle. This does not promise always-on background
  AI or access to texts sent manually in Messages.

## Verification

The revised core suite covers confident and uncertain partial answers, follow-up
without the old cooldown, evidence validation, identity, duplicate events,
completion, pause/cancel, expiry, agent-written replies, sent history and interrupted sends. Service
tests cover immediate automatic starts, permission-disabled proposals,
idempotency and unknown send outcomes. No live outgoing texts are used in tests.

The phone crash report also identified duplicate background-task registration
on reply recovery. Every retry now gets a unique registration identifier; a
regression test verifies that a late callback from the prior attempt is rejected.
No remote push is authorized.
