# "iPhone node is disconnected" after a fresh install (2026-09-17)

## What happened
- Input: first launch of a build that adds new node commands (Outlook
  Calendar). The phone node route checks the gateway config, finds the new
  commands missing, and patches the config (`config.patch`, 19:38:17.164).
- OpenClaw restarts its gateway after a config change. The chat's own socket
  died at 19:38:18.869 ("websocket reader ended with an error").
- The node route retried one second later (19:38:19.272 "opening local
  websocket"). The restarting gateway accepted the socket but never sent its
  `connect.challenge`. The handshake wait had no deadline, so the route sat
  there for good: no "route interrupted", no "own command surface verified"
  in the log until the app was relaunched.
- At 19:42:22 the owner asked for the Outlook event; the model called
  `connections.write` and the gateway answered that the iPhone node was
  disconnected. No event was created. (Outlook also still needed
  reconnecting at that point: `reauthorizationRequired` at 19:38:08 because
  the scope changed to Calendars.ReadWrite; the owner reconnected at 19:41.)

Evidence: scratchpad `hang.log`, pid 38981, lines 1044-1092 (thread-filtered
node route lines quoted in the chat).

## Fix
- `GatewayDeadline.handshake(milliseconds:)` bounds the connect handshake in
  both `OpenClawGatewayConnection` (chat/control) and `OpenClawNodeConnection`
  (phone node). Default 30 s (`GatewayDeadline.defaultMilliseconds`); on
  expiry the connect throws `OpenClawGatewayError.handshakeTimedOut`, the
  transport is closed, and the caller's normal retry loop takes over
  (`LocalLocationNodeGateway.runLoop` retries after 1 s).
- `LocalModelSetupGateway` treats `handshakeTimedOut` like any other
  transport outage while it waits for the gateway.
- Tests: `GatewayHandshakeDeadlineTests` (chat and node connection against a
  socket that opens and never answers).

## Same bug elsewhere?
- Searched every `transport.receive()` wait in OperatorCore: typed requests
  (`performRequest`), the node command loop and the chat stream also have no
  per-frame deadline. Those run on a socket that already completed its
  handshake; when the gateway restarts, that socket errors out (seen at
  19:38:18.869), so the wait ends. Only the handshake on a half-up listener
  hung silently. Left as is.
- `URLSessionGatewayTransport(timeout: 30)` sets URLSession's
  `timeoutIntervalForRequest`; it did not fire here (the socket was open, the
  server was just silent), so it is not a substitute.
