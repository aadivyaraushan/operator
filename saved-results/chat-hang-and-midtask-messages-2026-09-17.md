# Chat stuck on "Waiting", and messages sent mid-task (2026-09-17)

## The hang
- Input: a reply is still coming and Operator leaves the screen. Easiest way
  to hit it: "open the settings app" - the request itself sends Operator to
  the background.
- Expected: reply arrives, later messages go out.
- What happened: iOS froze the connection, so the send waiting on it never
  returned. Reconnecting is refused while a send is in progress, so nothing
  reconnected and every later message sat on "Waiting" forever.
- Fix: on leaving the screen the chat drops the connection
  (`letGoOfConnection`). The frozen wait then fails, the message goes back to
  waiting, and on return the normal reconnect picks up the saved reply.
- Checked for the same bug elsewhere: searched for `.receive()` in
  OperatorApp/Sources - the chat send loop is the only one.

## Messages sent while a reply is running
- OpenClaw's default for this channel is "steer": a `chat.send` during a run
  is folded into that run. The new message's own run ends empty; the answer
  comes under the first run's id. If steering is not possible OpenClaw queues
  it as a follow-up run instead (not tested).
- The app now sends the new message straight away on the open connection
  (`addToRunningRequest`) instead of queueing behind the running one, and
  treats the empty ending of the joined message as "answered by the earlier
  reply" rather than a failure.
- Composer: Stop shows only while working with an empty draft; otherwise Send.

## Also in this change
- `apps.open` with an appID that is both a listed website and an app (gmail)
  tries the app first, website only as fallback. App path for Gmail not
  verified: Gmail is not installed on the Simulator.

## Verified in the real app (QA Simulator, logs in scratchpad hang.log)
- Hang: sent "open the settings app", returned. Logs: "letting go of the
  connection", then "recovered saved completion before send", "reply persisted".
- Join: sent "Also tell me my battery level", then "and the weather in Austin
  too" while working. Logs: "added a message to the running request", "message
  was answered by the request it joined". One reply covered both (screenshot).
- Tests: 2 new model tests + 1 handoff test pass. Full suite: 504 run, only
  `SpotifyLoopbackSetupTests` fails (local callback never arrives on the test
  Simulator; untouched by this change, passed earlier the same day - cause
  not found).

## Known gaps
- No gateway-level tests for `addToRunningRequest` / `letGoOfConnection`.
- If a joined message waits over 5 minutes (OpenClaw forgets the send) and
  its empty ending was never seen, it could be sent twice.

## Follow-up the same day: replies that never "finish" (looked like a slow model)
- Input: "Wait are you sure you sent it?" at 13:30. The model answered in 14 s
  (transcript entry 1064, 13:30:34) but the chat stayed on "working"; two more
  messages queued behind it and were also answered in seconds, unseen.
- What went wrong: the app drops any chat event numbered no higher than the
  last one it saw for that run. OpenClaw sometimes restarts the count for the
  closing "final" event (it clears its per-run counter when the run's
  lifecycle ends, then numbers the final as 1: dist `chat-send-handler` 
  `nextChatSeq`, `server-chat` `finalizeLifecycleEvent`). The final was dropped
  with no log line. Evidence: log shows first-text then nothing for that run;
  transcript shows the reply complete. The OpenClaw numbering cause is read
  from its code, not seen on the wire.
- Fix: `GatewayEventReducer` order-checks only streamed text; final, error and
  aborted always count (a run already closed is still ignored). Test:
  `testAFinalNumberedLowerThanTheStreamStillEndsTheRun`.
- Verified: after installing, the three stuck replies were recovered on launch
  ("recovered saved completion before send" x3). Not yet seen: a live run
  where the low-numbered final arrives and is now accepted.
- Outlook "zero messages" earlier the same day: Microsoft returned 200 with an
  empty list; once a mail was sent to that account the read returned it. Sign-in
  uses Microsoft's personal-accounts-only address (`/consumers`).
- 2026-09-17 afternoon: owner confirms Outlook read and send work in the real
  app (inbox read returned the test mails; "hi" sent to ssdear@gmail.com,
  status 202).
