---
name: iphone-messages
description: Prepare a text in the iPhone system Messages composer when the user asks to message someone. The user reviews and sends it; no inbox access or automatic sending.
---

# Messages on iPhone

Use the connected iPhone node's `sms.compose` command, never `sms.send` or a shell workaround.

1. Resolve the intended recipient from information the user supplied or an authorized contact lookup. If the recipient is ambiguous, ask; never guess an address or number.
2. Use the nodes tool to discover the connected iPhone and confirm it declares `sms.compose`.
3. Invoke it with `action: "invoke"`, the discovered `node`, `invokeCommand: "sms.compose"`, and `invokeParamsJson` containing exactly `{"recipients":["the confirmed recipient"],"body":"the prepared text"}`. Both fields must be nonempty. Do not add fields or hardcode a node ID.
4. A result with `presented: true` means the composer opened. Say the draft is ready for the user to review and tap Send. `sent: false` and `deliveryVerified: false` mean no sending or delivery has been established. Never claim the message was sent based on this result.

If unavailable, inactive or blocked by another screen, explain that result and ask the user to open Operator or finish the current screen. Do not repeatedly reopen the composer, bypass Send, or fall back to an unapproved messaging service. This route cannot read Messages history. A failed or interrupted invocation is not permission to retry a potentially already-open composer automatically.
