# Discord: what read frequency gets an account banned?

**Date:** 2026-09-15
**For:** The owner's question, after setting up the Discord connector, of
how often Operator can read before the account is at risk. Read against the
pace the connector enforces (4 passes per 24 h, 2 h apart, one request per
listed channel, official iOS client headers, REST only).
**Sources checked:** Discord's self-bot support article (via search; the
support site refuses fetches), Discord Userdoccers reference
(docs.discord.food), DiscordChatExporter issue #1497, discussion #1308 and
PR #1510 with its source (DiscordClient.cs, Http.cs), PiunikaWeb 2026-03-12,
Rebane's report, nomsi's "Selfbot Rules" gist and comments, Angeryweb
2026-09-08, discord.py-self FAQ (#60), and, at the owner's request, sixteen
threads from r/Discord_selfbots (Sep 2025 to Aug 2026; read in a browser,
the listing is below).

## Bottom line

**Nobody has a number, including Discord.** Detection is behavioural and
unpublished; every source, from Discord's own article to the self-bot
library maintainers, refuses to name a safe rate. What exists is a record
of what *did* trigger enforcement, and all of it is orders of magnitude
above Operator's pace. The lowest-volume read-only enforcement found:
"a 24h ban after ~30 hours of continuous crawling." Operator makes at most
80 requests a day (20 channels × 4 passes), never two passes within two
hours, and holds no session between them. No report of enforcement at
anything like that scale was found.

The sanction, when it lands on read-only use, has been a **temporary
lock** (forced password reset, "platform abuse", logout with a community
guidelines notice), sometimes with a warning email, repeated on each new
attempt. Permanent termination is the stated ceiling, not the observed
first response.

## What changed in 2026

Until early 2026, read-only user-token tools ran for years with "very few
reports of anybody losing their account." From about March 2026 Discord
started locking accounts **as soon as they ran an export** with
DiscordChatExporter: one user, no trouble "in months/years", locked eight
times in one week (#1497, 2026-03-01). An export is hundreds to thousands
of `/messages` requests in minutes.

DiscordChatExporter's client sends a bare user token from a default .NET
HttpClient: no `User-Agent` of any client, no `X-Super-Properties`
(verified in `DiscordClient.cs` / `Http.cs`). The Userdoccers reference:
the header "is not required, but it is highly recommended due to its
significance in anti-abuse systems." PR #1510 added it:

| Report (PR #1510 comments) | Date |
| --- | --- |
| "working for a few hours on an account that got disabled twice without this change" | 2026-03-16 |
| "a 24h ban after ~30 hours of continuous crawling" (with the header) | 2026-04-01 |
| "still got banned the second time I tried" (with the header) | 2026-05-24 |

So the fingerprint matters and is not sufficient: with correct headers,
sustained volume still trips it. The PR was closed unmerged (2026-08-27).

## What the reports have in common, and what Operator does

| Reported trigger | Operator |
| --- | --- |
| Export bursts: hundreds to thousands of requests in minutes | ≤ 20 requests per pass, ≤ 4 passes a day |
| Continuous crawling for tens of hours | Passes 2 h apart minimum; no loop, no background |
| Requests with no client fingerprint | `User-Agent` and `X-Super-Properties` of the September 2026 iOS app |
| Fresh login (password reset) followed at once by a burst | Setup makes 1 + N small requests, once |
| Ignoring 429s and retrying ("API users that regularly hit and ignore rate limits will ... be blocked from the platform") | A 429 ends the pass and pauses the connector for a day |
| Spam, mass joins, command bots (the classic self-bot bans) | Read-only, no gateway, no writes |

Folklore from the self-bot community (nomsi gist comments) points the same
way: a warning email came after "like 30k logs"; advice is to cache, keep
human-like timing, keep it to a handful of servers, and keep the account
humanly active.

## The residual that cannot be measured

The official app never fetches messages without an open gateway session.
Operator sends iOS-app-shaped REST requests with no gateway session at
all. Whether Discord's anti-abuse models weigh that is unknown; no report
either way was found. It is the one signal Operator emits that the
official client never does, and it is why the second account remains the
right call whatever the pace.

## Consequence for the pace

The pace stays. Reads are the whole exposure, and the cache landed in
9159f8d makes re-asks free without loosening it. If the owner wants the
number that would change the risk class, it is not "3 passes instead of
4"; it is "a burst" or "a loop", and the guard forbids both.

## r/Discord_selfbots, read 2026-09-15

Anonymous, self-reported, and answered by people who run self-bots and
want to be reassured, so weak evidence on its own. It is consistent with
the DiscordChatExporter record above, which is why it is worth recording.

### On reads

| Thread | Ask | Answer |
| --- | --- | --- |
| "how likely is getting banned with a read-only selfbot?" (2026-01) | logs every message in a server | "It being read-only just makes you at the absolute lowest priority or chance of ever being caught" (+6); "I ran one for like 1 year straight ... scraping 27 discord servers" with rate limits and human-like on/off periods (+5) |
| "How to safely selfbot" (2025-10) | new to it | "Nobody is exempt ... unless you are doing absolutely no interacting, and only sourcing information with the bot passively" (+6); "So if the bot is read only, I'll be fine?" - "Yeah, you'll be pretty fine" |
| "Does discord actively ban self-botting if it isn't nefarious?" (2026-03) | funnel one channel into a desktop view | "it's only when you start interacting that they get angry. Just reading things is fine" |
| "Chance for ban for bot that listens inside a channel" (2026-05) | 24/7 listener on one channel | "you wont be banned, nor detected, at all" |
| "Channel monitoring selfbot" (2026-03) | ~100 channels every 30 minutes | "i don't think u can get banned for that since your simply reading messages" (nobody reports having done it) |
| "Risks of self-botting" (2026-05) | ~6,000 read requests a day at ~1/s | "You won't get banned" (one reply, unverified) |

No thread in the sample reports a lock or ban from reading alone.

### On what did get accounts disabled

| Thread | What was done | What happened |
| --- | --- | --- |
| "Any reason why this minimal DM self bot is being detected" (2025-11) | 3-4 DMs to a bot via discord.py-self | "After 3-4 messages, I receive this email without fail": suspicious activity, account disabled, password reset |
| "discord account disabled but not banned" (2025-11) | replies to DMs, "spams" a channel | every token disabled "after like 5 minutes" |
| "Discord detects self bots now???" (2025-09, +12) | ran a help command in a server after years of quiet use | 4-hour mute, logged out, password reset for "suspicious activity" |
| "How to safely selfbot" (2025-10) | auto-reply on ping got out of hand | muted, logged out, password reset, restricted for a few hours |
| "Detection?" (2026-04) | general | "don't mass dm, mass friend request, or mass join servers, and you're essentially risk free"; "detection is mostly occurred when using commands in DMs" |

### The 2026 escalation, seen from the other side

"Did Discord upgrade their anti bot?" (2026-08-20): "mid june discord
started flagging them instantly which led to them being disabled ... I used
to not have the browser headers, now i have them but it still detected. Is
it the x-properties?" Replies: "either HTTP client, headers, cookies or a
mix of all 3"; "yes they did everyone is getting banned"; "it's your
headers". That poster runs a fleet of freshly created accounts, which are
scrutinised far harder than an aged one, but the mechanism named is the
same one the DiscordChatExporter timeline shows: fingerprinting of the
HTTP client, not counting of requests.

Two details that bear on Operator:

- **The HTTP client itself is a signal.** A Python or .NET client on a
  desktop has a TLS fingerprint no Discord app has. Operator's requests
  come from URLSession on a real iPhone, the same stack the official iOS
  app is built on; with the iOS headers, that is the closest a self-bot
  can get to the genuine article without being it. Cookies the official
  app may send are the part Operator does not reproduce and cannot see.
- **"make some requests look authentic (and do websocket)"** - the
  community treats a gateway session as part of looking real. That is the
  residual named above; the sub confirms it is a known tell, not that it
  is acted on.

### What "disabled" means there

The sanction reported for every case above is the same: an email saying
the account "may have been compromised", the account disabled until the
password is reset, sometimes a mute of a few hours. One commenter notes
"That disabled thing happens to me all the time, I use no self bots or
anything" - the lock also fires on ordinary accounts, so a lock is not
proof of detection. A permanent ban shows at login with no end date.

### Net

Nothing in the subreddit moves the conclusion. Reads are the class every
answer calls lowest-risk, the reported locks are all writes or bursts,
and the 2026 change is about the fingerprint of the client, where a real
iPhone is the strongest position available. The pace stays.
