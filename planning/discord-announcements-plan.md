# Discord announcements digest

Written 2026-09-15, before implementation. Owner's ask: a TL;DR of the
announcement channels in servers they are in, about twice a day, with dated
items offered as Google Calendar events.

## Decision

Read through the owner's **own account** (a self-bot in Discord's terms),
read-only, from a channel list the owner picks, at a pace enforced in code.
The bot + Follow design was offered and rejected for this use: the servers
that matter do not all expose Announcement channels, and a bot cannot be
invited to a server the owner does not run.

Risk assessment given and accepted on 2026-09-15: Discord's policy forbids
this and the sanction is the whole account; reported enforcement is
behavioural (spam, joins, command bots, always-on sessions), read-only low
volume is the lowest-risk class, and the owner will use a second account.
See the conversation record in saved-results/ios-connectors-evidence.md.

## Guardrails, in code, not prose

- **Acknowledgement before the read grant**, the WhatsApp-send sheet, shown
  every time the grant is turned on. The catalog gains a read-side
  acknowledgement; the permission center and page stop assuming only writes
  carry one.
- **Fixed channel list** chosen by the owner in Operator (paste channel
  links). The model reads that list and nothing else; it cannot name a
  channel.
- **Pace**: at most 4 passes per rolling 24 h, at least 2 h between passes;
  one request per channel per pass; a 429 ends the pass and is honoured.
  Persisted in UserDefaults like the WhatsApp send history.
  *Amended 2026-09-15, after the first setup:* each channel is requested at
  most once every 10 minutes, at most 24 passes per rolling 24 h, and a
  channel inside its cooldown is answered from its last read (kept in one
  file in Application Support). The 429 rule is unchanged. Reasoning in
  saved-results/discord-read-frequency-ban-research-2026-09-15.md: every
  read-only lock on record was a burst or an unattended loop, and the
  guard's job is to make sure the model cannot turn the owner's questions
  into either; the old numbers rationed a human for no measured gain.
- **REST only**, never the gateway websocket: no always-on session, which is
  what the reported bans have in common.
- **Client headers** match the official iOS app's shape.
- **Token** stays in the Keychain, entered by the owner, never logged.
- **No writes**: no acks, no reactions, no sends. Reading does not mark
  channels read.

## Pieces, in order, each its own commit

1. `discord` connector in the catalog (read-only, requiresAccount, read
   acknowledgement); permission center/page generalised to read
   acknowledgements. Tests.
2. Token + channel list setup: `DiscordAccountSetupModel` (Keychain token,
   channel entries with owner label and id parsed from a pasted link),
   Connections sheet entry. A save validates the token with one
   `GET /users/@me` and resolves each channel name with `GET /channels/{id}`
   (once, at setup). Tests with a fixture transport.
3. `discord.announcements` command: reads the configured channels since a
   cursor, sanitises (author display name, timestamp, content, link, channel
   label), enforces the pace. Router, surface, policy allow, discovery,
   published tool. Tests.
4. Guidance for the digest (summarise per server, offer dated items as
   calendar events with the message link), QA bank, evidence.

## Not in scope

Proactive digests (the runtime only runs in the foreground), DMs, any write,
servers without a readable announcement channel, the shared-bot design.
