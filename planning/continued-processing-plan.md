# Finish the reply after the person leaves

Written 2026-09-16, before implementation. Owner's ask: a request should
not die when they switch away from Operator; the answer should be waiting
when they come back, and reach them as a notification.

## Decision

Use iOS 26's `BGContinuedProcessingTask`, the sanctioned way for an app to
finish a task the person started in the foreground after they leave. The
system shows its own progress pill (the person can end it), the process is
not suspended while the task runs, and the app reports progress and
completes the task. Nothing else is changed about where the runtime runs:
it still starts only in the foreground; this keeps it alive for one reply.

Scope is **one reply per task**: a task is submitted when a message is
sent with the runtime reachable, updated as the run reports activity, and
completed when the reply, a failure or a stop arrives. No polling, no
scheduled work, no always-on. Those belong on the Mac companion.

## What the API requires (SDK 26.6, verified in the headers)

- `Info.plist`: `BGTaskSchedulerPermittedIdentifiers` containing the
  wildcard `app.operator.ios.reply.*`.
- Register a launch handler for that identifier (continued tasks may be
  registered after launch, unlike other background tasks).
- Submit `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)`
  while foregrounded, strategy `.fail` so a refused submission is known
  at once and the reply simply runs foreground-only as today.
- The handler receives a `BGContinuedProcessingTask` with `progress`
  (NSProgress), `updateTitle(_:subtitle:)`, `expirationHandler`, and
  `setTaskCompleted(success:)`.

## Shape

```
send()  ──▶ ReplyContinuation.begin(messageID)   submits the request
                │  handler runs: keeps the task, sets progress 0/100
                ▼
ChatSessionModel updates ──▶ continuation.report(progress, subtitle)
   accepted 10, each step +, writing 80
                │
reply / failed / stopped ──▶ continuation.finish(success)
                │
scenePhase == .background while a task is active:
   runtimeIsForeground stays true  (chat websocket and node route stay up)
   on finish or expiration in the background: runtimeIsForeground = false,
   and the reply is posted as a local notification (first time: the
   notification permission prompt, asked in the foreground when the first
   task is submitted)
```

`runtimeIsForeground` becomes `scenePhase == .active || continuation.isActive`.
That is the whole lifecycle change: the existing background path runs
later instead of not at all.

## Limits, stated

- A step that needs the person (a write confirmation, a permission
  banner, `APP_NOT_ACTIVE` checks in the phone commands) still needs the
  app in front; in the background it fails as it does today and the model
  says so. Reads and the model's own work continue.
- If the system expires the task, the process is suspended; the existing
  recovery (the outbox entry, `chat.history` on return) finishes the reply
  when the person comes back, as it does now.
- Only one continuation at a time, for the message in flight.

## Pieces, in order, each its own commit

1. `ReplyContinuation` over a `ContinuedProcessingScheduling` protocol
   (submit, handler, progress, complete) with a fake in tests: begin,
   report, finish, expiration, one at a time, refused submission.
2. Wire it: Info.plist identifier, registration at app start, the
   foreground gate, the model's progress reporting from the live
   activity, completion on reply/failure/stop, the notification.
3. Live test with the owner: send, leave, watch the pill, get the
   notification, come back to the reply. Evidence.
