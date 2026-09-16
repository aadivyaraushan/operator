# WhatsApp ban risk when using Operator

**Date:** 2026-09-15
**For:** The owner's question after the first live WhatsApp reads and a
send on the phone. What Operator does, what WhatsApp's enforcement record
shows for that class of client, and where the residual risk sits.
**Sources checked:** WhatsApp Terms of Service (Acceptable Use); whatsmeow
issues #807 and #810 and PR #879; Baileys issue #1392 (33 comments, May
2025 to July 2025) and #2309; the GOWA review (artificiallyintimidating,
2026-08-26) with its maintainer quote; Wapisimo (vendor, no evidence,
noted and discounted); press on the 2015 and 2019 third-party-client
bans; the repo's own bridge code (read.go, send.go, WhatsAppSendGuard).

## What Operator does, from the code

| Aspect | Operator |
| --- | --- |
| Client | wacli 0.17.1 on whatsmeow (pinned 2026-08-06), the Go library behind mautrix-whatsapp and Beeper |
| Link | A companion device, like WhatsApp Web, paired by phone-number code; it appears in the phone's Linked devices list under the client's own name |
| Read | `connect → sync once (contacts, groups, channels, history) → idle 5 s → disconnect`; chats and messages are then read from the local store. No always-on session |
| Send | `connect → send text → close`. Only to a chat that already exists, never a new conversation; at least 20 s apart; at most 20 in 24 h; every message shown for a tap first (`WhatsAppSendGuard`) |
| Network | From the phone itself, on its own mobile or Wi-Fi address, not a server |
| Account | **The owner's real number.** There is no second-account option: the chats live on it, as with Instagram DMs and unlike Discord |

## WhatsApp's position

Terms of Service, Acceptable Use: users must not "involve sending illegal
or impermissible communications such as bulk messaging, auto-messaging,
auto-dialing, and the like", nor "reverse engineer, alter, modify ... or
extract code from our Services", nor "gain or attempt to gain unauthorized
access to our Services or systems"; "we may take action with respect to
your account, including disabling or suspending your account". Third-party
clients have been actioned since 2015 (WhatsApp Plus: 24-hour blocks, then
permanent). A companion-protocol library is an unofficial client under
these terms.

## The enforcement record for this class of client

**May 2025 was the episode that matters.** From about 7 May 2025 WhatsApp
began showing "Your account may be at risk. Recent activity indicates that
your account may be using unauthorized tools." to accounts linked through
whatsmeow, Baileys, *and* whatsapp-web.js (which drives the real WhatsApp
Web in a browser). Facts from the two threads:

- It hit low-volume accounts: "even for really low usage clients (5
  messages a day)" on residential IPs (Baileys #1392, 2025-05-09); clients
  "only replying to incoming messages" (whatsmeow #810).
- It hit accounts that were **idle but connected**: "never send a message
  from it they are just connected" (#810, 2025-05-10), and accounts that
  had been connected weeks earlier and no longer were.
- Some warned accounts were banned, including "my account of 8 years"
  (#1392, 2025-05-27) and "old numbers" (2025-06-04).
- The Baileys maintainer's read: "This is mostly a behavioral issue, not
  a WAM issue" - i.e. not a protocol fingerprint, since the browser-driven
  client got it too. Enabling Meta Verified on a business account stopped
  the warnings for some.
- By June 2025 the warnings faded: "I just ignored it and the message
  disappeared over time." The whatsmeow issue was closed "not planned" on
  2026-07-06 with no fix; PR #879 (WAM telemetry) was never merged.

**Steady-state bans, 2025-2026**, are behavioural and fast: new numbers
messaging people who do not have them saved are "almost certainly
restricted immediately"; one report of a ban after "approximately 5
messages"; account recreation with test messages "immediately get hit";
status uploads from a server (Baileys #2309, 2026-01). The GOWA maintainer
(2026-07-25): "There is no limit on this side, and I cannot confirm any
number as safe ... the blocking decision is made entirely on WhatsApp's
side." Aged numbers with real contact history "fare better".

**The counterweight**: whatsmeow "is used by many Beeper users every day
with no issues" (Hacker News, repeated in two 2026 write-ups). That is a
large population doing reads and personal sends through exactly this
library, from personal accounts, continuously. No source quantifies it.

## Sanction ladder, as reported

Warning banner → temporary block (24 h reported for third-party clients)
→ permanent ban. Appeals are opaque; permanent bans of aged personal
numbers were reported in 2025. A permanent ban is the number: chats,
groups, and the identity people have for you.

## Where Operator sits against the record

| Reported trigger | Operator |
| --- | --- |
| New or recreated numbers | The owner's aged number with years of history |
| Messaging people who do not have you saved | Existing chats only, by construction |
| Volume, identical messages, bursts | ≤ 20/day, ≥ 20 s apart, each different and tapped by the owner |
| Server or datacenter IPs | The phone's own address |
| Status uploads, media blasts | Text only |
| Always-on unofficial session | Connects per operation, disconnects after |
| Idle-but-linked companion (May 2025 warnings) | **Applies.** Operator is a linked device whenever it is linked, whether or not it connects |
| Unofficial client fingerprint at all | **Applies.** WhatsApp can see the linked device's client; the May 2025 episode shows Meta will warn this class at any volume when it chooses |

## Bottom line

The risk is real and it is specific: it does not come from what Operator
sends, which is far below every reported behavioural trigger, but from
**being an unofficial linked device on the owner's real number**. In May
2025 that alone drew warnings, and for some accounts bans, at any volume;
since then the same population (Beeper) has run untroubled. Nobody,
including the library authors, can put a number on it, and the sanction
is the number itself. This is the one connector where the standing
no-ban-risk rule is knowingly overridden by an acknowledgement rather
than satisfied by a second account.

What reduces the exposure, in order of effect:

1. **Keep sends off unless needed.** Reads are the lower-risk half; the
   send grant is per-session by design.
2. **Unlink when not in use** (WhatsApp > Linked devices > log out). A
   device that is not linked cannot be scored.
3. **If the "account may be at risk" banner ever appears in WhatsApp,
   unlink Operator at once and stop.** In 2025 it preceded bans; in some
   cases it faded after the tool was removed.
4. Never use it for a new contact, a repeated message, or anything that
   looks like outreach; the guard already refuses the first, the owner's
   tap is the check on the rest.
