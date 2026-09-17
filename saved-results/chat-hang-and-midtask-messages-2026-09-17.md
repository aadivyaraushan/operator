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
