# Incoming texts, without a Mac

Written 2026-09-15, before implementation. Owner's ask: know what people
text them (SMS and iMessage) from Operator, on the phone alone.

## Decision

iOS gives no app a way to read the Messages inbox: no framework, no
permission, no notification listener, no Shortcuts read action. The one
sanctioned door is the Shortcuts **"When I get a message" automation**,
which since iOS 17 can run immediately, with no confirmation, while the
phone is locked, and passes the received message to whatever it runs
(Apple: Communication triggers; MacMost demonstrates the any-sender and
locked cases). So Operator gets a **feed of incoming messages**, not an
inbox: everything received from the moment the automation exists, nothing
before, nothing the owner sent, no read state, no attachments.

No ban risk: this is Apple's own automation system driving Apple's own
app intent surface. No acknowledgement sheet; a plain read grant, off by
default, because the content is the owner's texts.

## Shape

```
Messages ──iOS──▶ Shortcuts automation ("When I get a message", Run Immediately)
                       │  runs Operator's "Record incoming message" intent
                       ▼
             RecordIncomingMessageIntent (in-app AppIntent, background)
                       │  appends {sender, text, receivedAt}
                       ▼
             IncomingMessageStore  (Application Support/Operator/incoming-messages.json,
                                     newest first, capped at 500 and 14 days)
                       │
      messages.incoming node command ──▶ messages_incoming tool ──▶ the model
```

The intent runs in the app process; a background launch for it constructs
the app's objects but never starts the Node runtime, which only the
foreground task does (OperatorApp.swift, `runtimeIsForeground`).

## Guardrails, in code

- **Read grant** on the Messages connector, default off, shown on the
  Permissions page with the setup steps. The command is refused without
  it like every other read.
- **Bounded store**: at most 500 messages, nothing older than 14 days,
  file protection until first unlock (the intent must write while locked).
- **Sanitised output**: sender as the automation gave it (name or handle),
  text, receivedAt; a `limit` of 1…100 (default 25) and `sinceRFC3339`.
- **Nothing is sent** by this path; replies go through the existing
  sms.compose / sms.send grants.
- **Setup is the owner's**: personal automations cannot be installed from
  a link, so the Permissions page gives the six taps.

## Pieces, in order, each its own commit

1. `RecordIncomingMessageIntent` + `IncomingMessageStore` with tests
   (append, cap, age, dedupe of the same message delivered twice).
2. Catalog: Messages gains the read side (`messages.incoming`, summary,
   setup instructions). Node surface, policy allow, published tool
   `messages_incoming`, discovery note, router, wiring. Tests updated for
   the surface list.
3. Guidance line for the model; evidence entry; first live test with the
   owner (the automation on the phone, one text, one read).

## Open until the live test

- The exact names Shortcuts offers for the input's text and sender when
  the automation's action is an app intent (expected: the input itself
  coerces to the text; "Sender" is a property of the input).
- Whether group messages carry the group name (not expected; the sender
  is still there).
