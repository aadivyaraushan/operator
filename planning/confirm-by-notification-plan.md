# Confirm a send from a notification

Written 2026-09-16, before implementation. Owner's ask: when Operator is
working in the background and wants to send a WhatsApp message, ask by
notification, with Send and Don't send buttons, instead of handing back a
draft that needs the app opened.

## Decision

The tap stays; where it happens changes. On screen, the confirmation is
the alert it is today. Off screen, with a reply being kept alive, the
confirmation is a notification with two actions. The **Send** action
carries `authenticationRequired`, so the phone must be unlocked to press
it, and the app handles the press in the background: it sends, then
posts a second notification saying it did (or why it could not). The
model's tool call does not wait for the tap; it returns at once with
"asked by notification" and is told to say the message goes when the
person taps Send, never that it was sent.

The tap is invisible to WhatsApp, so this changes nothing in the ban
record; it is about the owner seeing the exact message before it goes.
The guard (existing chats only, 20 s apart, 20 a day) runs **before** the
notification is posted, so a refused send never reaches a notification,
and **again** at the tap, since minutes may have passed.

## Shape

```
whatsapp.compose (background) ──▶ guard ──▶ PendingSendStore.add(draft)
                                        └─▶ notification "Send to Villa?" [Send] [Don't send]
                                        └─▶ tool result {sent:false, askedByNotification:true}

tap Send ──▶ UNUserNotificationCenter delegate ──▶ PendingSendCenter.perform(id)
                 guard again ──▶ sender.send ──▶ recordSend, outcome recorded,
                 a line appended to the chat ("Sent to Villa on WhatsApp: …"),
                 notification "Sent to Villa" or "Couldn't send: …"
tap Don't send / dismiss ──▶ entry removed, nothing sent
expiry: an entry older than 10 minutes is refused at the tap
```

The pending store is a small JSON file in Application Support: a tap
can arrive after the process was suspended and relaunched, so the draft
cannot live in memory.

## Guardrails, in code

- Only when a continuation is active and the app is not on screen; on
  screen the alert is unchanged; with neither, the refusal is unchanged.
- The Send action requires authentication (device unlocked).
- Guard before posting and again at the tap; the second run's refusal is
  itself a notification, so the person knows.
- One pending send per recipient at a time; a newer draft replaces the
  older one's notification.
- Expiry at 10 minutes; expired entries are pruned on every access.
- The chat gets the outcome as a line, so the transcript shows what went.

## Pieces, in order, each its own commit

1. `PendingSendStore` (file, bounded, expiry) and `PendingSendCenter`
   (ask, perform, decline) over a `SendConfirmationNotifying` protocol
   and the existing `WhatsAppTextSending` + `WhatsAppSendGuard`, with
   tests: ask posts and stores; perform re-guards, sends, records,
   notifies, appends; decline removes; expiry refuses; a replaced draft.
2. The compose service's background branch: guard, then ask, then the
   "asked" payload. Guidance line for the model. Tests.
3. The notification category and delegate in the app (registered at
   launch; the delegate is retained by the App), wiring, live test.

## Not in scope

Texts via the shortcut and contact saves by notification: the same
center can take them next; WhatsApp first because it is the send the
owner uses.
