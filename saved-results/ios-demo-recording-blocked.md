# The demo recording is blocked: the agent never calls the native connectors

Date: 2026-09-11
Device: iPhone 16 Pro simulator `7EED8360-33E3-46F0-92B3-5F5F116C6A08`, iOS 18.6
Goal: capture a screen recording of Operator completing a real errand, for the
landing page.

## Result

Not recordable yet. The node is connected and paired; the agent does not use it.

## What works

- **Recording.** `xcrun simctl io … recordVideo` produces a real file:
  1206x2622, h264, verified with ffprobe. ffmpeg is available to trim/convert.
- **Model sign-in.** The ChatGPT device-code flow completed; the "Connect
  ChatGPT" button is gone and the agent answers.
- **Seeded data.** 6 calendar events and 5 reminders inserted with
  `ios/Tools/seed-demo-simulator.py`; Apple's 6 sample contacts ship with the
  simulator already.
- **Node pairing.** From the device log:

      [location-node] connected protocol=3-4 commands=location.get,
        calendar.events,reminders.list,contacts.search,photos.latest,
        music.nowPlaying,music.search,weather.forecast,device.status,…
      [node-pairing] inspected ownPending=0 ownPaired=1
      [node-pairing] exact native surface already approved
      [location-node] own command surface verified

  All 26 commands are registered and the surface is approved. The pairing fix
  in 1bf4c3a holds across a cold boot.

## What does not work

Two prompts, both of which should have hit `reminders.list`:

| Prompt | Reply |
| --- | --- |
| "What is on my plate today?" | "From what I can currently access, **nothing is recorded for today** — no saved tasks, reminders, or deadlines. I can't verify your calendar or inbox because no logged-in browser session is connected." |
| "List my open reminders." | "You have **no open reminders**. The two active scheduled jobs are internal maintenance tasks, not personal reminders." |

Both are wrong: there are 5 seeded reminders, 4 of them open, and 6 events.

## The evidence that pins it down

**iOS never asked for permission.** EventKit cannot read reminders or calendar
without a consent prompt, and the prompt never appeared. The simulator's TCC
database confirms it:

    sqlite3 …/data/Library/TCC/TCC.db \
      "select service,client,auth_value from access where client like '%operator%'"
    -- (no rows; 36 rows exist for other clients)

No TCC row means `EKEventStore` was never asked. So this is not a permission
denial, not a seeding failure, and not a query-window bug — **the connector was
never invoked at all**.

The second reply is the useful one: "the two active **scheduled jobs**" shows
the agent did call a tool — one of openclaw's own built-ins — and reached for
the scheduler when asked about reminders. It had tools; the node's commands
were not among them.

## Conclusion

The gap is between the gateway and the agent session, not in the connectors and
not in pairing. The node registers its 26 commands with the gateway and the
gateway approves the surface, but the model is not offered those commands as
tools, so it answers from its own built-ins and from general knowledge.

This is worth more than the video: every connector proof in
`ios-connectors-mac-checklist.md` Stage 3 would fail the same way, because none
of them can be exercised through the chat surface yet.

## Next

1. Find where the agent session builds its tool list and why node commands are
   absent. Pairing approval is evidently not sufficient.
2. Re-run the two prompts above. The pass condition is visible and cheap: iOS
   shows a Reminders permission prompt, and a TCC row appears for
   `app.operator.ios`.
3. Then record. Everything else for the take is ready.

## Notes for whoever picks this up

- Simulator automation works but is fussy. `cliclick` for taps, and always
  `du:x,y` (release) before `c:x,y` — a stale drag leaves iOS showing a text
  magnifier loupe that ruins a frame. Type with `osascript … keystroke`, not
  `cliclick t:`, which drops characters at this speed.
- The Simulator window must be activated before System Events can see it, or
  window lookup fails with `-1719`.
- Calendar/AddressBook stores were backed up before seeding; the seeder refuses
  to run twice.

---

# Update, later the same day: the connectors work; the account is rate limited

Three defects fixed since the above. The agent now calls the native
connectors, which it had never once done.

## 1. The node published no agent tools (e90bcf9)

The cause named in the original write-up. openclaw builds the model's tool
list from descriptors a node sends with `node.pluginTools.update`; this node
sent none, so the gateway held 26 commands and the model was handed zero.
Eight read-only descriptors are now published on connect.

Proof, in order:

    [location-node] published agent tools count=8
    [location-node] handling command=device.status
    [device] returned online=true lowPower=false
    [location-node] handling command=reminders.list

and the pass condition set out above was met exactly: iOS raised the
Reminders permission prompt, and TCC went from **no row for
`app.operator.ios` at all** to `kTCCServiceReminders|2`.

The agent said it best itself, on the turn after the fix:

> My earlier "none" answer only checked OpenClaw reminders - not Apple
> Reminders. Sorry about that.

## 2. The first real call crashed the app (032c192)

`EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`, from
`EventKitReminderStore.incompleteReminders(limit:)`. A closure written inside
a `@MainActor` type is assumed main-actor isolated, so Swift emits an
executor check; EventKit calls back on its own queue and the check traps.
The same shape was latent in calendar, contacts and music - all four fixed.

This one is only findable by a live call. The unit tests drive these stores
through fakes, and a fake calls back on whatever queue the test is already
on, so the assertion never fires.

## 3. The websocket was killed every 30 seconds (b4ac9e1)

`timeoutIntervalForResource` bounds the whole task, and it was set to the
handshake timeout. The socket carrying both chat and the node died thirty
seconds after opening, every time - which read as the agent saying "your
iPhone is disconnected" rather than as a timeout. CFNetwork `-1001`,
`transaction_duration_ms=30114`, against a `101` upgrade.

## What actually blocks the recording now

Nothing in the code:

    API rate limit reached. Please try again later.

Runs come back `blocked` / `run_blocked` in `audit_events` within about two
seconds and never reach a tool. Ruled out first: session transcript (cleared
the openclaw state DB and the app conversation, same result on a clean
session) and tool-schema quarantine (no quarantine record exists, so the
descriptors were accepted).

It is the ChatGPT account's own limit, spent on today's testing. It resets
with time; there is nothing to fix.

## Still open

- **Seeded reminders are invisible to EventKit.** `reminders.list` runs and
  returns `count=0` against 5 seeded rows. The Reminders app agrees it has 0,
  so the rows are wrong, not the connector. `DEFAULT_TASK_CALENDAR_NAME`
  (calendar 3, store 1) is the list the app shows as "Reminders", and rows
  land in it, but neither EventKit nor the Reminders UI counts them - so
  something beyond summary/dates/entity_type is required. The next move is to
  create one reminder through the UI and diff its row against a seeded one.
- **Contacts needs no seeding.** The simulator ships Apple's six sample
  contacts with 25 numbers, so `contacts.search` is the connector to demo
  first once the limit clears.
- **openclaw bakes an absolute workspace path** into
  `agents.defaults.workspace` at first init. A reinstall changes the data
  container UUID, so the runtime then fails with `WorkspaceVanishedError` and
  the chat stops working. No app code writes this key. Dev-only - an App
  Store update keeps the container - but it bites on every `simctl install`.
  Workaround used here: rewrite the key to the current container before
  launch.

---

## 2026-09-12: what made the two-turn demo possible

Two changes were needed before a multi-turn run could be recorded, and both
are product findings rather than filming tricks.

### Timed calendar events, via subscription

Writing rows into `Calendar.sqlitedb` does not work on iOS 18 (see the
runbook). The method that does: serve an `.ics` over the loopback and hand it
to the simulator with

    xcrun simctl openurl <udid> "http://localhost:8899/day.ics"

iOS offers its own **Add Subscription Calendar** flow - Subscribe, then
Continue past the insecure-connection warning, then Add. The events land in a
subscribed calendar that EventKit reads. `calendar.events` went from
`count=0` to `count=5`.

### The agent stalled when it could not act

Asked "im lowk sick, fade everything", the run was accepted and then never
finished - four minutes, no tool calls, no reply, no error. The agent has
eight read tools and nothing that sends a message or moves an event, and it
had no instruction for that situation.

Fixed by appending a section to `AGENTS.md` in the openclaw workspace, which
openclaw loads as agent instructions: when asked for something you have no
tool for, do not stall and do not refuse - write out exactly what you would
send and change, drawn from what you just read, then say it is waiting on
them. The same question now answers in **6.5 seconds** with three drafted
messages and a named list of cancellations.

**This is not in the repo.** openclaw generates `AGENTS.md` on first run and
the edit lives only in that simulator's workspace, so a clean install loses
it. Making it permanent means the app seeding that guidance into the
workspace it creates - worth doing, because the stall is a bad failure mode
for any user who asks for something the agent cannot do, not just for a demo.
