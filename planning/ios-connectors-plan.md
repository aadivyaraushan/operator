# Operator iPhone — additional connectors plan

**Date:** 2026-09-10
**Branch:** `codex/ios-connectors`, cut from `codex/ios-operator`.
**Follows:** [saved-results/ios-connectors-handoff.md](../saved-results/ios-connectors-handoff.md).
**Status:** Phases 0, 2, 3 and 4 are implemented and locally verified. Phase 1
(live authorization) and Phase 5 (writes) are not started — Phase 1 needs the
Mac, and Phase 5 is gated on it. No connector has been proven against a real
account. Per-connector state lives in
[saved-results/ios-connectors-evidence.md](../saved-results/ios-connectors-evidence.md).

## Decisions this plan was written under

| Decision | Value |
| --- | --- |
| Selection criteria | Daily personal utility, and low authorization friction. Nothing else. |
| Order within a connector | Reads before writes, everywhere, with no exceptions. |
| Definition of done | Live authorization plus one real read, per connector. A fixture pass is not done. |
| Exclusions | The handoff's exclusion list stands: no Beeper, no Instagram messaging bridge, no Discord automation or self-bot, no unrestricted iMessage inbox, no notification listening. |
| Todoist / Teams | Left out. They were not taken off the shelf, so this plan does not port them. |
| Verification host | Another developer's Mac — the one with Xcode and the existing Simulator. |

## Where work actually runs

This machine was measured, not assumed, on 2026-09-10.

| Capability | This machine | Consequence |
| --- | --- | --- |
| Go tests (`go test ./companion/...`) | Works, green | All companion-side work is fully testable here |
| Node tests (`node --test **/*.test.mjs`) | Works, green | The hand-off catalog contract is testable here |
| Swift connector fixtures (`Tests/**/run.sh`) | **Fails: `no such module 'XCTest'`** | XCTest ships with Xcode, not Command Line Tools. Every Swift suite runs on the Mac |
| `xcodebuild` / `simctl` / iOS SDK | **Absent.** No `/Applications/Xcode*.app` | No build, no Simulator, no install, no live login here |
| `ios/build/` native dependencies | Not staged | NodeMobile, openclaw runtime and the wacli archive all missing |
| Go toolchain | 1.26.5 vs wacli's pinned 1.26.6 | Soft: the build script sets `GOTOOLCHAIN=go1.26.6`, which self-fetches |

**Working split.** Everything Swift and everything live happens on the Mac. Everything Go, everything Node, and all authoring happens here. Each phase below states which side it lands on.

## Connector selection

Ranked by the two chosen criteria. The organizing insight is that **authorization friction is dominated by whether a new developer-console registration is needed at all**, and the two highest-utility tiers need none.

### Tier 0 — no OAuth of any kind

System permission prompt only. No console, no client ID, no callback, no network, no review. The app already proves this shape in `ForegroundCalendarService` (EventKit).

| # | Connector | Read to prove | Cost |
| --- | --- | --- | --- |
| 1 | **Apple Reminders** (EventKit) | List reminder lists and open reminders | Mirrors `ForegroundCalendarService` almost line for line — same framework, already linked. Needs `NSRemindersFullAccessUsageDescription` in `Info.plist` |
| 2 | **Contacts** (`CNContactStore`), read-only | Resolve a name to phone/email | Needs `NSContactsUsageDescription` |

Contacts is ranked this high for a compounding reason rather than a direct one. `sms.compose` and `whatsapp.compose` today need a handle the user already knows. Contacts is what turns "text Mom" into something the agent can act on, so it raises the ceiling of connectors that already exist. Android has `capability/routing/contacts`; iOS has nothing equivalent.

### Tier 1 — existing OAuth client, new scope only

No new registration, no new callback, no new console app. A scope string on a provider that is already configured, plus a re-consent.

| # | Connector | Scope added to | Read to prove | Note |
| --- | --- | --- | --- | --- |
| 3 | **Gmail** (read) | `.google` — `gmail.readonly` | Recent message headers | Highest single daily utility on this list |
| 4 | **Microsoft Calendar** (read) | `.microsoftOutlook` — `Calendars.Read` | Events in a window | Delegated, no admin consent. Natural pair for the mail already wired |
| 5 | **Google Tasks** (read) | `.google` — `tasks.readonly` | Task lists | Stretch. Cheap once #3 lands |

**Gmail caveat, stated up front.** `gmail.readonly` is a Google *restricted* scope. Under the project's current Testing mode with test users it works with no extra process, which is why it qualifies as low friction today. A public launch would need a CASA security assessment. That is a ceiling on the connector, not a blocker for proving it.

### Tier 2 — hand-off breadth

Opening an app, never completing an action. Ceiling is permanently `hands_off`.

Measured against the current 76 IDs, the absent daily-utility apps that are **eligible**: **Gmail**, **Google Calendar**, **Slack**, **Notion**, **Waze**, **Yelp**, **Zoom**, **Ticketmaster**, **Instacart**.

Adding app-open entries for Gmail, Google Calendar, Slack and Notion is worth doing even though credentialed connectors for those services exist or are planned: it mirrors the companion's own design, where the deep-link pack is the floor every install gets signed in or not, and the credentialed adapter takes over the same id when a real connection loads.

**Ineligible, and not by oversight.** An earlier draft of this plan named Amazon as the largest gap. That was wrong, and the correction matters more than the omission:

| App | Class | Why it can never ship |
| --- | --- | --- |
| **Amazon** | C2 | Court-enjoined. A federal judge granted Amazon a preliminary injunction against Perplexity's shopping agent in March 2026. Repo standing order: *"do not point a browser at it."* Recorded at `deeplink/adapter.go:206` and across the consumer-app plans |
| Robinhood, Coinbase, banks | C2 | Money movement is a prohibited action class |
| Strava | — | Explicitly named as do-not-build in the Wave 1 walls |
| Reddit (commercial) | — | Same |
| Dating apps | C3 | Never shippable |

Consent class C is not a warning label; `manifest.Validate()` refuses it outright, so a C2 adapter cannot be registered even by mistake.

### Considered and rejected

| Candidate | Why not |
| --- | --- |
| GitHub, Linear | Friction genuinely is low (self-serve, PKCE / device flow), but "daily personal utility" is weak unless you say otherwise. Parked, not dismissed |
| Telegram, Signal personal accounts | Not named in the handoff's exclusions, but personal-account automation is the same shape as the excluded Discord self-bot. Out on the same principle |
| **Apple Notes on iOS** | No public iOS API exists. `main`'s `applenotes` adapter is macOS AppleScript via `osascript` and cannot be ported. Recording this so nobody spends a day discovering it |
| Photos (PhotoKit), HealthKit | Tier-0 friction, but weaker assistant utility. Parked |
| Todoist, Teams | Left off the table by decision |

## Why a hand-off connector cannot buy anything

Recorded here because "what stops the agent spending money" is the first question any commerce-adjacent connector should have to answer, and the answer is currently spread across four files.

**Six independent layers, all already in place:**

1. **The verb does not exist.** `pay` is deliberately absent from the nine verbs. `manifest.go`: *"money movement is deep-link only forever."*
2. **Shopping specs declare `Read` only.** Target, Walmart, Nike, Sephora, Wayfair and eBay all carry `Verbs: [Read]` and `AppClass: "shopping"`.
3. **The agent cannot supply a URL.** `apps.open` accepts an `appID` and an optional draft, nothing else — *"URLs are not accepted."* The destination is looked up in a closed 76-entry allowlist.
4. **Allowlist destinations cannot carry a query string or fragment.** `AppHandoffCatalog.isSafeDestination` requires `query == nil && fragment == nil`, enforced at catalog-decode time *and* re-checked at open time in both `ForegroundAppHandoffService` and `SystemAppHandoffOpener`. A destination therefore cannot physically encode a product, a cart, a quantity, or a one-click token. It is a bare landing page.
5. **It fails closed.** A missing or malformed catalog sets `destinations = [:]` and disables app opening entirely rather than falling back to opening arbitrary URLs.
6. **The result never claims completion.** The success payload is `actionCompleted:false, draftTransferred:false`, with `nextStep` stating the owner must complete any action.

Separately, `GateBilling` exists in the manifest vocabulary but **nothing in the product can clear a gate** — `CheckGates()` refuses any gate that is not `none`, in the user-facing runner and the unattended verification runners alike.

**What is genuinely still exposed:**

- `SFSafariViewController` shares cookies with Safari, so opening a retailer lands the owner in a *logged-in* session. Operator cannot tap anything, but it has shortened the distance between a chat message and a purchase. Layer 4 is what keeps that distance from being one tap: a landing page is not a cart.
- **The human is the automation.** The realistic failure is not Operator buying something — it is Operator saying *"I've added it to your cart, just tap Buy"* when it did nothing of the kind. This is exactly what the `Handed off` state mark in `DESIGN.md` exists to prevent: never claim success after hand-off, and never claim failure either.
- **Scope creep.** The moment a real commerce API and the `order` verb are wired, layers 3 and 4 stop applying. `order` already exists, `RequiresPreview()` is true for it, and DoorDash and Grubhub already declare it. The guardrail there is the mandatory preview plus the plan fingerprint check in `Execute`.

**The one real gap, and it is cheap to close.** Nothing enforces the class-to-verb relationship. That shopping specs are read-only is convention held in a source comment — precisely the failure mode this repo keeps naming: *a rule that lives in someone's memory rather than in a check.* A new spec with `AppClass: "shopping"` and `Verbs: [Order]` passes every test in the tree today. Phase 4 closes it.

## The extension seam

To add a **credentialed** connector, five places change:

| Step | File |
| --- | --- |
| Provider, scopes, endpoints | `ios/OperatorApp/Sources/connections/auth/OAuthTypes.swift` — `OAuthProvider` (4 cases today) |
| Read operation | `ios/OperatorApp/Sources/connections/services/read/DirectAccountReader.swift` — enum case plus arms in `valid()`, `url()`, `page()` (7 ops today) |
| Write operation | `ios/OperatorApp/Sources/connections/services/write/DirectAccountWriter.swift` (6 ops today) — **not touched by this plan** |
| Tool exposure | `ios/OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift` plus `GatewayNativeNodeSurface.commands` |
| Callbacks / permissions | `ios/OperatorApp/Info.plist` (explicit and checked in — do not regenerate) |

`connections.describe` in `ForegroundConnectionDiscoveryService` derives its advertised surface from those enums, so discovery costs nothing extra per connector.

To add a **hand-off** connector, six places change, and Go is the source of truth:

1. `companion/internal/capability/adapters/deeplink/adapter.go` — a `Spec` in `Wave1Specs()`, with a `ProvesCeiling` name
2. `companion/internal/capability/adapters/deeplink/adapter_test.go` — the `want` list and its count assertion
3. `android/app/src/main/kotlin/app/codexlauncher/capability/handoff/HandOffActions.kt` — display name to package
4. `ios/OperatorApp/Resources/connections/handoff/android-handoff-catalog.json` — the iOS destination
5. `ios/OperatorApp/Tests/capabilities/handoff/catalog/catalog-completeness.test.mjs` — three hardcoded counts (76 total, 66 `webOpenedOfficial`, 7 `officialSearchVerified`)
6. Nothing else

**Confirmed not affected:** `proof_names_resolve_test.go` pins dangling proof names at 15 on this branch, but `everyAdapter` builds only `Wave1Specs()[0]` as the deep-link representative. Adding hand-off connectors does not move that pin. Adding a *credentialed* adapter to the companion would.

## Phases

### Phase 0 — reproducible bootstrap  *(here + Mac)*

The handoff states plainly that a checksum-pinned dependency setup "remains work for the next developer", and that no clean-clone bootstrap was ever executed. Until that exists, no second developer can build, which makes it the true first task rather than a chore.

- Write `ios/Runtime/bootstrap.sh`: verify the NodeMobile artifact against a recorded checksum, stage openclaw via the existing `run.mjs`, build the wacli archive via the existing `build.sh`, and refuse to overwrite existing outputs the way both current scripts already do.
- Write `ios/Runtime/DEPENDENCIES.md` recording the three artifacts and their checksums.
- **Here:** a `--check` dry-run mode, plus Node tests for the staging logic.
- **Mac:** one full run from a clean clone, ending in a successful `xcodebuild`.

**Exit:** a second developer can go from `git clone` to a built app using only checked-in scripts.

### Phase 1 — prove the five existing sign-ins  *(Mac; blocks Phase 3)*

This is the handoff's own steps 2 through 4, and it comes before any new credentialed connector because every Tier-1 connector rides the same tokens. Gmail cannot be proven until Google sign-in is proven.

Order: **Google → Outlook → Slack → Spotify → Notion.** For each: authorize inside Operator (never a dashboard Install button), perform one real read, quit, relaunch, and prove restoration and refresh.

On any failure, capture the safe error name before restarting anything:

```sh
xcrun simctl list devices booted
xcrun simctl spawn SIMULATOR_UDID log show --last 10m --style compact \
  --predicate 'subsystem == "app.operator.ios" AND category == "phone-oauth"'
```

Before installing on the original Mac, inspect the existing app state. Do not erase the Simulator, do not uninstall, do not install over an active login without looking first.

**Exit:** five providers authorized, five real reads, restoration and refresh proven, no writes performed.

### Phase 2 — Tier 0 native connectors  *(authored here, verified on Mac; parallel with Phase 1)*

These depend on no token, so they proceed while Phase 1 is blocked on a browser.

- **2a Apple Reminders read** — `ForegroundRemindersService` as a `GatewayNodeCommandHandler`, command `reminders.list`, modelled on `ForegroundCalendarService` including its access-state enum and foreground guard. Register in the router and in `GatewayNativeNodeSurface.commands`. Add `NSRemindersFullAccessUsageDescription`. Fixture suite at `ios/OperatorApp/Tests/capabilities/reminders/run.sh`.
- **2b Contacts read** — `ForegroundContactsService`, command `contacts.resolve`, read-only, returning at most a bounded number of matches. Add `NSContactsUsageDescription`. Fixture suite alongside.

**Exit per connector:** fixtures green on the Mac, permission granted on a real launch, one real read returned through chat.

### Phase 3 — Tier 1 scope-only connectors  *(authored here, verified on Mac; needs Phase 1 green per provider)*

- **3a Gmail read** — `gmail.readonly` on `.google`; `AccountReadOperation.gmailMessages`; arms in `valid()`, `url()`, `page()`; fixture suite.
- **3b Microsoft Calendar read** — `Calendars.Read` on `.microsoftOutlook`; `outlookCalendarEvents`; same shape.
- **3c Google Tasks read** — stretch, only if 3a landed cleanly.

**Expect a re-consent.** Adding a scope invalidates the existing grant for that provider; the user must authorize again. This is exactly why Phase 3 sits after Phase 1 rather than beside it — re-consenting a sign-in that was never proven working would confuse two failures.

### Phase 4 — hand-off breadth  *(almost entirely here)*

Add the eligible daily-utility apps through the six-step path above. Go and Node tests both run here; only the in-app open smoke needs the Mac.

Never let a catalog entry claim more than it does. The existing `provesOnly` wording is the standard: an official landing page proves a page opened, not that the app exists on the device and not that anything was accomplished in it.

**Three enforcement tests land in this phase, before any new spec.** All three run here, none needs the Mac, and together they convert three standing orders from prose into checks:

- **Class-to-verb.** No spec with `AppClass` of `shopping` or `money` may declare `Order`, `Book`, `Send`, `Write`, `Cancel` or `Modify`. Closes the gap named above.
- **Prohibited ids.** A pinned denylist — `amazon`, `strava`, `robinhood`, `coinbase`, and the dating apps — that fails if any appears in `Wave1Specs()` or the iOS catalog. Turns "do not build Amazon" from a sentence in a planning document into a failing test.
- **No commerce paths.** No catalog URL path may look like a cart, checkout, buy, order or payment endpoint, in addition to the existing no-query-string rule.

### Phase 5 — writes

**Out of scope until every read above is proven live.** Named here so it is visibly deferred rather than forgotten. No message sent, no mail sent, no event created, no file created, no playback started — the handoff's standing instruction, and unchanged by this plan.

## Evidence table

Kept updated in `saved-results/ios-connectors-evidence.md`, one row per connector, per the handoff's step 6. A row may only leave `unproven` when a human watched it happen.

| Connector | Fixtures | Authorized live | Real read | Restored after relaunch | Notes |
| --- | --- | --- | --- | --- | --- |
| *(one row per connector; all start unproven)* | | | | | |

## Risks

- **Single verification host.** One Mac holds Xcode, the Simulator and the account state. Everything live is serialized behind one person. Phase 0 exists partly to reduce that.
- **Re-consent churn.** Each Tier-1 scope addition forces re-authorization of a provider proven in Phase 1. Batch scope additions per provider rather than landing them one at a time.
- **Google Testing mode.** Test-user restrictions apply, and `gmail.readonly` is restricted. Fine for proving; not a path to public release.
- **Spotify development mode** caps connected users. Not a blocker for one developer, a blocker for a beta.
- **The catalog test parses Go source with a regex** (`/\{ID:\s*"([^"]+)"/g`). Reformatting `Wave1Specs()` silently changes what it sees. Any spec edit should be followed by running the Node suite here.
- **The existing Simulator's half-finished Google login** may or may not still be in that state. Inspect before acting; the handoff is explicit that its state must not be assumed.

## Open question

**GitHub and Linear are parked, not rejected.** They score well on authorization friction and poorly on "daily personal utility" only because that phrase was read as personal rather than professional. If work tools count, they move into Tier 2 ahead of the hand-off breadth.
