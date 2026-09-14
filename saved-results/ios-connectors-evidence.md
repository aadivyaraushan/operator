# iPhone connectors — evidence

Updated 2026-09-10. Branch `codex/ios-connectors`.

Phases 0, 2, 3 and 4 of the plan are written and locally verified. Phase 1 (live
authorization) and Phase 5 (writes) are untouched — Phase 1 needs the Mac, and
Phase 5 is gated on Phase 1 by the reads-before-writes rule.

**Read the columns literally.** "Fixtures" means a test suite passes. "Live"
means a person watched a real account answer through Operator. Nothing in the
second column is claimed by anything in the first, and no row below has a live
result yet, because the machine this work was written on has no Xcode.

## What ran, and where

| Check | Where | Result |
| --- | --- | --- |
| `go test ./companion/...` | here | pass, 0 failures |
| `node --test` (catalog completeness, commerce safety, project sources) | here | pass, 3/3 |
| Service and reader logic, ported to swift-testing | here | pass, 39/39 |
| `swiftc -parse` on the committed XCTest suites | here | pass |
| `Tests/**/run.sh` (the committed XCTest suites) | **Mac** | **not run — XCTest ships with Xcode** |
| `swift test` (OperatorCore) | Mac, 2026-09-11 | pass, 81/81 |
| `xcodebuild` + `simctl install` + launch | Mac, 2026-09-11 | **BUILD SUCCEEDED**, installed, paired |
| ChatGPT device-code sign-in | Mac, 2026-09-11 | **authorized live** |
| Reminders permission granted on a real call | Mac, 2026-09-11 | **granted** — `kTCCServiceReminders\|2` |

The 39 swift-testing checks are a local port of the committed XCTest
assertions, written to verify the logic on a machine that cannot run XCTest.
They exercise the same code paths and the same expectations. They are not the
committed suites and they are not evidence that the committed suites pass.

## Per connector

| Connector | Tier | Fixtures written | Fixtures green on Mac | Authorized live | Real read | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Apple Reminders (`reminders.list`) | 0 — no OAuth | yes | **no** | **yes** — prompt shown and granted | **partial** | Command reaches the handler and returns cleanly; see 2026-09-11 below |
| Contacts (`contacts.search`) | 0 — no OAuth | yes | **no** | **no** | **no** | Renamed from `contacts.resolve` so openclaw can pair it |
| Device (`device.status`) | 0 — none | yes | **no** | n/a | **yes** | `returned online=true lowPower=false` through a real agent call |
| Microsoft Calendar (`outlookCalendarEvents`) | 1 — scope only | yes | **no** | **no** | **no** | Forces Microsoft re-consent; see below |
| Gmail (`gmailMessages`) | 1 — scope only | yes | **no** | **no** | **no** | Forces Google re-consent; see below |
| Google Tasks (`googleTasks`) | 1 — scope only | yes | **no** | **no** | **no** | Kept |

### Google Contacts and Chat were dropped, 2026-09-11

Built, then removed before anyone authorized them, on the principle that the
phone already supplies the same data for free:

- **Google Contacts** duplicated `contacts.resolve`, which reads the phone's own
  address book with no OAuth, no review and no annual re-verification — and on a
  consumer iPhone that book is usually already synced from Google.
- **Google Chat** is a Workspace product with thin consumer use: two scopes
  reaching message content, for the narrowest audience of anything on the list.

The remaining Google scopes are `calendar.events`, `drive.file` (the narrow
per-file scope), `gmail.readonly` and `tasks.readonly`. A test pins the two
dropped families out so reinstating either has to be an argument.

### Google scope debt

**Correction, 2026-09-11.** An earlier version of this section, and the commit
message for the Google connectors, stated flatly that `gmail.readonly`,
`contacts.readonly` and both chat scopes are *restricted* and that `drive.file`
is among them. That was asserted from memory, not checked, and `drive.file` in
particular is the deliberately narrow per-file scope — Google's own reference
describes it as "only the specific Google Drive files you use with this app",
which is the cheap alternative to the broad Drive scopes, not a costly one.

What was actually verified on 2026-09-11, by reading the pages:

- Google's public OAuth scope reference carries **no** sensitive/restricted
  labels at all. The classification is not there to be read.
- The API Services User Data Policy confirms "Sensitive and Restricted Scopes"
  exist and carry **Limited Use** obligations, and that apps requesting
  restricted-scope data need **annual re-verification**.
- The per-scope classification lives in each product's own policy and in the
  OAuth Application Verification FAQ. It was not confirmed for these scopes.

So: the exact tier of each scope is **unconfirmed** and should be settled from
the verification FAQ before any launch planning depends on it. What is not in
doubt is the direction — more Google scopes means more verification work, and
four of the scopes now requested reach personal content.

### The Limited Use question this raises

The User Data Policy requires that use of scope data be limited to user-facing
features, that transfers to third parties are prohibited except to provide
those features with the user's consent, and that humans must not read the data
without the user's affirmative agreement.

Operator sends message and contact content to **OpenAI** for inference
(`LocalModelSetupGateway.swift:109`, `openai-device-code`). That is a transfer
to a third party. It is plausibly inside the "to provide your user-facing
feature, with consent" exception — it is how any assistant works — but it is a
live compliance question, it needs a lawyer's read rather than an engineer's,
and it needs a consent flow that actually says so. It is the same shape as the
Apple DPLA §3.3.3(J) collision already recorded in
[phase0-ios-capability-ceiling.md](phase0-ios-capability-ceiling.md).

## Native iPhone connectors (Tier 0)

Added 2026-09-11, completing the base set. None needs OAuth, a registration or
a review; each needs a permission string, and one needs an entitlement.

| Connector | Command | Permission | Notes |
| --- | --- | --- | --- |
| Photos | `photos.search` | `NSPhotoLibraryUsageDescription` | Returns descriptions only — ids, dates, kinds, albums. **Never image data.** Partial access reported |
| Music | `music.nowPlaying`, `music.search` | `NSAppleMusicUsageDescription` | The owner's own library. No playback verb: playback is a write |
| Weather | `weather.forecast` | none | Takes an explicit coordinate; does not read location. **Needs an entitlement — see below** |
| Device | `device.status` | none | Battery, power, connectivity, locale, time zone. No identifier of any kind |

`weather.forecast` and `device.status` are in `commandPolicyAllow`; a public
fact about a caller-supplied coordinate and a device state carrying no
identifier are not personal data. Photos and Music are not, and follow
calendar, reminders, contacts and location.

### WeatherKit needs more than a permission string

`com.apple.developer.weatherkit` must be enabled on the App ID, which requires
a paid Apple Developer account. Unlike everything else in this table it cannot
be satisfied from source, and without it every call fails at runtime. Apple
also requires visible attribution wherever the data is shown; the service puts
the attribution string in its own payload so it cannot be lost on the way, but
**rendering it is an outstanding UI debt.**

### A bug this work surfaced in already-shipped code

`JSONSerialization` bridges `0` and `1` to an `NSNumber` that satisfies
`is Bool`. The obvious guard against `{"limit": true}` therefore also rejected
`{"limit": 1}`, and **Reminders and Contacts refused a limit of exactly one**
from the day they shipped. Weather would have refused the coordinate 0,0.

Fixed by `OperatorCore.JSONNumber`, which uses `objCType` — the idiom
`ForegroundAccountReadService` already used — in one place instead of five. A
regression test pins every affected boundary.

## Hand-off connectors (Phase 4)

Eight added, taking the pack from 76 to 84: Gmail, Google Calendar, Slack,
Notion, Waze, Zoom, Ticketmaster, Instacart. These are a different kind of
thing from the four above — they open an app or its website and can never do
more, so "live authorization" does not apply to them. What *was* verified:

| Check | Result |
| --- | --- |
| Play Store id resolves | all 8 answer 200 |
| The check discriminates | a fake id answers 404, and the run reproduced the two 404s already recorded in the source (`com.lyft.android`, `com.viator.mobile.consumer`) |
| Destination answers over HTTPS | 8 of 9 candidates; Yelp answers 403 to any non-browser request and was left out rather than recorded as unverified |
| Go, Kotlin and iOS catalog agree | `catalog-completeness` pins the id sets to each other and passes |
| No prohibited service or commerce path | `commerce-safety` passes |

Still unproven: that any of them actually opens on a device. That needs the
Mac, like everything else in the second column.

## Reproducibility (Phase 0)

`ios/Runtime/bootstrap.sh` now exists, with `--check` and `--pin` modes that
work without Xcode, and [DEPENDENCIES.md](../ios/Runtime/DEPENDENCIES.md)
records all three artifacts.

**NodeMobile is still unpinned.** The script refuses to stage it until someone
runs `--pin` against an artifact they downloaded themselves and records the
hash. That is the one remaining step before a second machine can build.

A CI workflow (`.github/workflows/ios.yml`) runs every check that does not need
Xcode. The Swift suites are still a Mac step.

## Two things the first Mac run will hit

**Both Microsoft and Google now demand a re-consent.**
`requiredAccessTokenScopes` is a hard gate at `PhoneOAuthClient.swift:242`, so
a token granted before `Calendars.Read` and `gmail.readonly` existed will fail
validation. Whether the restore path degrades cleanly to "needs setup" or
surfaces an error is **unverified** and is worth watching on the first launch.

The connectors plan sequences Tier 1 after the existing sign-ins are proven for
this exact reason. The handoff records Google as currently failing with "Try
again". If that is still true, revert `ac30d7c` (the gmail.readonly scope, kept
as its own commit so it can be reverted alone), fix sign-in against the existing
scopes, and put it back afterwards.

**The pairing surface changed.** `reminders.list` and `contacts.resolve` were
added to `GatewayNativeNodeSurface.commands`, which is matched exactly against
the gateway's stored surface. An already-paired node will need re-approval.

Neither new command was added to `commandPolicyAllow`. That is deliberate and
follows `location.get` and `calendar.events`: personal data is never added to
the policy Operator installs into the gateway on the owner's behalf.

## What is not started

Writes. Every connector above is read-only, per the plan's reads-before-writes
rule, and no write path should be written until each row above has a real read.

---

## 2026-09-11/12: first live connector calls, and what the MVP still needs

### Rows that moved

`device.status` is the first connector with a genuine end-to-end result: an
agent call reached the handler and it answered `online=true lowPower=false`.
`reminders.list` reaches the handler and returns cleanly, and iOS raised and
recorded the Reminders permission - `kTCCServiceReminders|2`, where before
there was no TCC row for the app at all. It is marked **partial** rather than
proven because the answer has not yet come back through chat as text a person
read; see the rate limit below.

Three defects had to be fixed before any of that was possible, each hiding the
next: the node published no agent tools (e90bcf9), the first real EventKit
call trapped on a `@MainActor` executor check (032c192), and the gateway
websocket was capped at a 30-second total lifetime (b4ac9e1).

### Still unproven, and why

- **The five OAuth sign-ins.** Phase 1 of the plan is untouched. The device
  log still reports `saved connection unavailable` for `microsoftOutlook`,
  `slack` and `spotify` on every launch. Nothing in Tier 1 - Gmail, Outlook
  Calendar, Google Tasks - can be proven until this is.
- **`contacts.search`, `photos.latest`, `music.*`, `weather.forecast`.**
  Written, published as tools, never called live. Contacts needs no fixture
  (the simulator ships six sample people), so it is the cheapest next proof.
- **`music.*` cannot be proven on a simulator at all** - there is no media
  library. It needs a device.
- **`weather.forecast`** still needs the `com.apple.developer.weatherkit`
  entitlement, which needs the $99/yr Apple Developer Program.

### What blocks the next session

The ChatGPT account is rate limited. Runs return `blocked` / `run_blocked`
within about two seconds without reaching a tool, and the app shows
"API rate limit reached." It persisted across two and a half hours, so it
looks like a daily or plan-level cap rather than a short window. Ruled out
first: session transcript (cleared the state DB and conversation, same
result) and tool-schema quarantine (no quarantine record exists).

### Two bugs found but not fixed

- **openclaw bakes an absolute workspace path** into
  `agents.defaults.workspace` at first init. Any reinstall changes the data
  container UUID and the runtime then dies with `WorkspaceVanishedError`.
  Dev-only - an App Store update keeps the container - but it bites on every
  `simctl install`. Workaround: rewrite the key before launch.
- **A stray "UI probe reminder"** is in the simulator's Reminders list from
  fixture work. Cosmetic; delete before filming.

### MVP gaps that are not connector work

- **No settings or permissions surface exists** (issue #23). There is no
  screen anywhere in `OperatorApp/Sources` that lets a person see or revoke
  what Operator can reach. Every limit we ship is currently invisible and
  unchangeable from inside the app.
- **The evidence rule still holds.** A row may only leave `unproven` when a
  human watched it happen. Most rows above are still machine-observed only.

---

## 2026-09-14: first run on a physical iPhone

Device: iPhone 17 (`iPhone18,3`), iOS 26.6.2, free Apple Development
signing, team set in the gitignored `Local.xcconfig`. Automatic provisioning
created the `app.operator.ios` profile on the first device build, so the
bundle ID was not held by another team.

### What was proven

| Check | Result |
| --- | --- |
| Device build signs | yes — `Apple Development`, `get-task-allow` |
| Embedded Node boots under the iOS sandbox | **yes** — the open question from 261f925 |
| Gateway ready on a fresh install | yes, 10.8s |
| Gateway ready on relaunch with existing state | yes, 7.5s |
| Chat websocket connects, `sessions.messages.subscribe` completes | **yes** — first time on a device |
| Node connects, publishes 8 agent tools, surface approved | yes |
| ChatGPT sign-in, any connector call | **not yet** — nothing below the runtime has been exercised |

### Three sandbox failures, each hiding the next

All three read as the same "Operator's bundled runtime could not start."
The status file gave the stage and bundled frames; the phone's own log gave
the cause each time, as a one-line `Sandbox: Operator deny(...)` entry.

1. **`/tmp` is outside the sandbox** (fb809a0). openclaw hardcodes `/tmp` for
   its lifecycle lock database. Patched at staging time to honour
   `OPERATOR_STATE_LOCK_DIR`, which the host sets to `<state>/locks`.
2. **The container root is not writable** (ad64a31). openclaw's read-only
   SQLite snapshot root is `~/.cache/openclaw`; on iOS `~` is the container
   root, where only `Documents`, `Library` and `tmp` may be created. Fixed
   with `XDG_CACHE_HOME=<state>/cache`, which openclaw already honours.
3. **iOS re-homes the data container on every install** (ee768a7). The
   recorded `WorkspaceVanishedError` bug, now fixed in `prepareState`.

### Two facts worth knowing before touching the runtime again

- **`process.platform` is `"ios"` under NodeMobile, not `"darwin"`.** Every
  `=== "darwin"` branch in openclaw is skipped on the phone (and, presumably,
  on the Simulator). The `.cache` path above is how this surfaced.
- **The Simulator hides every one of these.** Its `/tmp` is the Mac's, its
  container sits on a filesystem that allows dotfiles at the root, and its
  container UUID is stable across `simctl install` most of the time. A
  Simulator pass says nothing about the sandbox.

### How to read the phone

`xcrun devicectl` cannot stream logs. What worked, with no sudo and no
system install:

```sh
python3 -m venv pmd3 && pmd3/bin/pip install pymobiledevice3
NO_COLOR=1 pmd3/bin/pymobiledevice3 syslog live -m Operator
```

Then relaunch and grep for `Sandbox: Operator` and `[embedded-runtime]`.
The runtime's own status file is at
`Library/Application Support/Operator/openclaw/native-runtime-status.json`
in the app container, readable with `devicectl device copy from`.

One benign denial remains in every launch: `deny(1) process-fork`. Something
in openclaw tries to spawn a child at startup and carries on when refused.
Not investigated.
