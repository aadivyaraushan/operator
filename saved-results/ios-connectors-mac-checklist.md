# What to test on the Mac

For the developer with Xcode and the existing Simulator. Written 2026-09-11
against branch `codex/ios-connectors`.

Everything below was written on a machine with **no Xcode**. Go and Node checks
pass there; every Swift suite, every build and every live account is unproven.
That is what this list is for.

**Order matters.** Stage 0 needs nothing but Xcode and finds the most likely
breakage in minutes. Do not skip ahead to the interesting parts.

---

## Before touching anything

The original Simulator may still hold a half-finished Google login. **Inspect
it before you install over it.**

```sh
xcrun simctl list devices booted
```

- Do **not** erase the Simulator.
- Do **not** uninstall the app.
- Do **not** send a message, send mail, create an event, create a file, or
  start playback. Every connector added is read-only by design; if something
  appears to offer a write, stop and say so.
- Do **not** link WhatsApp or test a WhatsApp send.

---

## Stage 0 — the fixture suites (needs only Xcode, ~10 minutes)

**This is the highest-value thing you can do and it needs no accounts, no
device and no bootstrap.** 58 XCTest functions were added across three new
suites, and nobody has ever compiled them against XCTest — the machine they
were written on has Command Line Tools only, where `import XCTest` fails. Their
logic was verified by porting the assertions to swift-testing, and every file
passes `swiftc -parse`, but that is not the same as compiling.

Three suites are brand new:

```sh
bash ios/OperatorApp/Tests/capabilities/reminders/run.sh
bash ios/OperatorApp/Tests/capabilities/contacts/run.sh
bash ios/OperatorApp/Tests/capabilities/native/run.sh
```

Two existing suites were modified and must be re-run:

```sh
bash ios/OperatorApp/Tests/connections/read/run.sh
bash ios/OperatorApp/Tests/connections/discovery/run.sh
```

Then the rest, to be sure nothing else moved:

```sh
swift test --package-path ios/OperatorCore
for suite in auth write media confirmation setup notion notion-node notion-callback spotify-loopback; do
  bash "ios/OperatorApp/Tests/connections/$suite/run.sh" || echo "FAILED: $suite"
done
```

**What failure looks like here:** a compile error in test code, not a logic
failure. If you get one, it is almost certainly mine — send the error, it will
be quick to fix.

---

## Stage 1 — make the tree buildable (~30 minutes, mostly downloads)

Nobody has ever built this from a clean clone. The blocking step is one
checksum.

```sh
sh ios/Runtime/bootstrap.sh --check          # reports what is missing
sh ios/Runtime/bootstrap.sh --pin /path/to/nodejs-mobile-ios-24.18.0-0.zip
```

**Pin from an artifact you downloaded yourself**, not a hash anyone sent you.
Record the result in two places: `expected_nodemobile_sha` in
`ios/Runtime/bootstrap.sh`, and the table in `ios/Runtime/DEPENDENCIES.md`.
Then:

```sh
sh ios/Runtime/bootstrap.sh NODEMOBILE OPENCLAW_PACKAGE WACLI_SOURCE
```

See `ios/Runtime/DEPENDENCIES.md` for what those three are and where they come
from. The script refuses to overwrite an existing output, so delete one
deliberately if you need to rebuild it.

**Then build**, exactly as the original handoff specifies, and install
**without erasing existing app data**.

---

## Stage 2 — the node has to be re-approved

The pairing surface is matched exactly, and it grew from 21 commands to 26.
An already-paired node will need approving again. Expect this; it is not a
bug. If pairing silently fails instead of asking, that *is* a bug — say so.

---

## Stage 3 — the four new native connectors (no accounts needed)

These need a permission tap and nothing else. This is the cheapest real
evidence available, so get it before touching any sign-in.

| Ask the agent | Expect | Watch for |
| --- | --- | --- |
| "What's on my reminders?" | A permission prompt, then incomplete reminders, at most 25 | Also try a limit of exactly **1** — that boundary was broken until this branch |
| "What's Mom's number?" | A permission prompt, then matches | Asking it to "list all my contacts" must be **refused**, not answered |
| "Find photos from last Tuesday" | A permission prompt, then descriptions | The reply must contain **no image data**. If a picture appears, stop and report it |
| "What am I listening to?" | A permission prompt, then the track | Asking it to play, pause or skip must be **refused** |
| "What's my battery?" | An answer with no prompt at all | The reply must contain **no device name, model or identifier** |

**Weather is expected to fail** unless `com.apple.developer.weatherkit` is
enabled on the App ID — that needs the paid Apple Developer account. If you
can enable it, do; if not, report it as blocked rather than broken.

---

## Stage 4 — Google sign-in, the known blocker

The original handoff records Google failing with "Try again". Nothing since
then has fixed that; a callback-parser repair was installed and never
confirmed.

**Expect a re-consent.** Scopes were added since the last grant
(`gmail.readonly`, `tasks.readonly`, `Calendars.Read` on Microsoft), and
`requiredAccessTokenScopes` is a hard gate at `PhoneOAuthClient.swift:242`, so
an older token now fails validation. Two things to watch:

1. Does the app degrade cleanly to "needs setup", or surface an error? That
   path is unverified.
2. If sign-in still fails, capture the safe error **before** restarting
   anything:

```sh
xcrun simctl spawn SIMULATOR_UDID log show --last 10m --style compact \
  --predicate 'subsystem == "app.operator.ios" AND category == "phone-oauth"'
```

**If plain Google sign-in cannot be made to work, revert commit `ac30d7c`**
(the `gmail.readonly` scope, kept separable for exactly this reason), fix
sign-in against the old scopes, and put it back afterwards. Do not debug two
failures at once.

---

## Stage 5 — one real read per account (only after Stage 4 is green)

Order: **Google → Outlook → Slack → Spotify → Notion.** One at a time.
Authorize inside Operator, never from a provider's dashboard.

| Connector | Minimal proof |
| --- | --- |
| Google Calendar | Events in a window |
| Google Drive | A file search |
| Gmail | Recent message headers |
| Google Tasks | Task list contents |
| Outlook mail | Inbox headers |
| Outlook calendar | Events in a window |
| Slack | Channel list, then one channel's history |
| Spotify | A search. **Do not start playback** |
| Notion | Tool discovery, then one read |

An empty-but-successful result is acceptable evidence. A stored token is not.

Then quit, relaunch, and confirm connections restore, tokens refresh, and
history and unsent drafts survive.

---

## What to send back

Per connector: worked / failed / blocked, and for anything failing, the safe
error name from the log predicate above. Please update the table in
[ios-connectors-evidence.md](ios-connectors-evidence.md) rather than replying
in prose — that file is the running record, and every row in it currently says
unproven.

## What I most expect to break

1. A compile error in the new XCTest suites (Stage 0) — never compiled anywhere.
2. WeatherKit, on the missing entitlement.
3. Google sign-in, which was already failing before any of this.
4. The re-consent path degrading badly rather than cleanly.

Everything else has been exercised against stubs, which proves the logic and
proves nothing about a real account.
