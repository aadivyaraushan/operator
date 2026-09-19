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

## Found at the live test

- On the owner's iOS 26 the Message trigger will not proceed with both
  Sender and Message Contains empty (Apple's guide and the iOS 17
  walkthroughs say it does). The filter that catches nearly everything is
  Message Contains with a single space; one-letter automations (e, a, o,
  i, u) cover one-word texts, and the store's two-minute duplicate window
  makes several automations firing for one text harmless.
- `shortcuts://create-automation` opens Shortcuts on the trigger picker
  (undocumented, verified on the iOS 18 Simulator); the Permissions page
  offers it. The automation itself still cannot be created by an app.

## Open until the live test

- The exact names Shortcuts offers for the input's text and sender when
  the automation's action is an app intent (expected: the input itself
  coerces to the text; "Sender" is a property of the input).
- Whether group messages carry the group name (not expected; the sender
  is still there).

## Easier setup and two-sided summaries (2026-09-18)

Implemented the follow-up setup plan:

- Permissions → Messages now gives numbered steps and a Check setup button,
  showing the last received preview, sender, relative time and retained count.
  It refreshes on appearance and when Operator becomes active. Sent entries
  never count as evidence that the incoming automation works.
- A shared store feeds the setup model and read command. Writes from separate
  store instances are serialized in-process so the background intent and send
  callbacks cannot overwrite each other's entries.
- Successful shortcut sends and the system composer's Sent result record a
  `sent` entry. Failed, cancelled and unknown sends do not. Legacy entries
  decode as `received`; incoming duplicate suppression does not drop actual
  repeated sends. The read result uses `direction` and `from` / `to`.
- Summary guidance groups recent activity by person and flags likely requests
  for replies, while acknowledging that replies typed directly in Messages
  remain unavailable.

The follow-up plan's iOS 27 filterless-trigger and natural-language-builder
claims were not verified. The shipped copy therefore describes the Message
trigger and says what to do *if* Shortcuts requires a filter, without promising
OS-specific features or complete coverage. Device confirmation of those
Shortcuts behaviors and a real incoming test text remain manual checks.

### iOS 27 setup documentation follow-up

Apple's current iOS 27 guide confirms adding a trigger from a shortcut's
Edit → Automation section, and Info → Privacy → Allow Running When Locked:
https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/10.0/ios/27
Apple also documents describing a shortcut with Apple Intelligence:
https://support.apple.com/en-euro/guide/iphone/dom122pp864g/27/ios/27

Setup now leads with that editor flow, offers a describe-it alternative with
review of the generated trigger/text/sender, and collapses older-iOS/filter
instructions into a disclosure. The undocumented create-automation URL is only
shown below iOS 27. Check setup remains the evidence of incoming capture.

Correction to the earlier follow-up plan: Apple's WWDC26 presentation lists
screenshot, keyboard and **notification** as the three new triggers, not Message:
https://developer.apple.com/videos/play/wwdc2026/310/
The Message trigger already existed; Apple's communication-trigger guide still
lists Sender and Message Contains. Filterless capture and correct generated
Operator field wiring remain unverified on the phone.

### Owner-verified prompt route

The owner confirmed the generated Run Shortcut wrapper records an incoming text
when Message Contains is one space and Run Shortcut receives Shortcut Input.
The first run required Allow for the installed shortcut to run Operator actions.
Asking the generator to add Operator's third-party action directly was refused;
asking for an unfiltered trigger left a placeholder filter and did not work.

Permissions now includes Copy setup prompt for the verified wrapper and first-run
permission instructions. Its default target is the exact title of the current
shared shortcut, with an editable override for renamed or duplicate installs.
No renamed shortcut was published: the install link and default target name must
be updated together if the shortcut is re-shared. The space filter is explicitly
partial coverage. The setup check asks for a new text/time rather than treating
historical received messages as proof of a newly configured automation.
