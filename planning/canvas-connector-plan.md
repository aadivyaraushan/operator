# Canvas connector

Written 2026-09-17, before implementation. Owner's ask: a Canvas
integration, pointing at CanvasArchive
(github.com/xavierahojjx-afk/CanvasArchive) or whatever fits best.

## Decision

**Canvas's own REST API, from the phone, with the owner's personal access
token.** Not CanvasArchive: that is a Python bulk downloader for a laptop
(every course's files into folders, then Google Drive), and its one
transferable fact is how it authenticates - a token the student makes
under Canvas > Account > Settings > *Approved Integrations* > New Access
Token, sent as `Authorization: Bearer`, against `https://<school>/api/v1`.
That is the Discord connector's shape (paste a token in Connect
accounts) with none of its risk: Canvas documents these tokens for
exactly this use, there is no terms problem, no ban to warn about, and
no developer key - which would need the school's Canvas admin - is
involved. So: Tier-0 friction, official API, reads only.

Reads first, per the connectors plan; no writes in this pass (no
submissions, no posts).

## What it reads

Three commands, each one published tool, chosen by what a student asks
daily:

| Command | Canvas | Answers |
| --- | --- | --- |
| `canvas.courses` | `GET /courses?enrollment_state=active&include[]=term&include[]=total_scores` | "what classes am I in", "what's my grade in X" (current score and letter per course, when the course shows them) |
| `canvas.upcoming` | `GET /planner/items?start_date&end_date` (default the next 7 days, `days` 1..30) plus `GET /users/self/missing_submissions` | "what's due", "what do I owe", with submitted / missing / late per item |
| `canvas.announcements` | `GET /announcements?context_codes[]=course_<id>…&start_date` over the active courses (default the last 14 days, `days` 1..60) | "any announcements", "what did I miss" |

Announcement bodies are HTML; they are stripped to text and bounded.
Every read has a page cap and a byte cap, and a 429 is surfaced as
`RATE_LIMITED` with the retry time, never retried.

## Setup

Connect accounts > Canvas: the school's Canvas address (host or URL,
kept in UserDefaults, it is not a secret) and the token (Keychain,
service `app.operator.ios.canvas`). Saving makes one `GET /users/self`
and shows the name it returns. No acknowledgement: nothing here can cost
the owner an account.

Permissions page: a `Canvas` row, read only, `requiresAccount`.

## Pieces, in order, each its own commit

1. OperatorCore: `ConnectorID.canvas` and its catalog row; the three
   commands on the node surface and the policy allow list; three tool
   descriptors.
2. App: `CanvasClient` (Bearer, pagination by the `Link` header, bounded),
   `CanvasAccountSetupModel` + view, `ForegroundCanvasService` with the
   three commands, router, discovery, activity words, app wiring. Tests
   with a routed fake transport, per the Discord suite.
3. Guidance section for the model; re-stage the runtime.
4. connector-qa bank `canvas.json`.
5. Live: the owner's token on the phone, one real read of each.

## Not in scope

Files and downloads (CanvasArchive's actual job), submissions, grades
per assignment, discussions, writes of any kind, and OAuth developer
keys.
