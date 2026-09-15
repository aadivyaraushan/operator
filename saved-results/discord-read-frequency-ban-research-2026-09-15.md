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
2026-09-08, discord.py-self FAQ (#60).

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
