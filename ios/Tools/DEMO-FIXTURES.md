# Putting demo data on the simulator

What a recording of the read connectors needs on the device, and how to get it
there. Written after getting this wrong once.

## Do not write to Calendar.sqlitedb

There is an obvious-looking shortcut: write rows straight into

    ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/Calendar/Calendar.sqlitedb

It does not work on iOS 18, and it fails silently, which is the worst part.
The rows insert cleanly, survive a boot, and are visible to `sqlite3` - and
neither EventKit nor Apple's own apps ever see them. Measured on iOS 18.6:

- 5 reminders and 6 events inserted with the correct `entity_type`
  (2 for events, 3 for reminders) into the calendars whose
  `supported_entity_types` say they accept them.
- `reminders.list` through the connector returned `count=0`.
- The Reminders app showed **0**; the Calendar day grid was empty across the
  hours the events were seeded into.
- A reminder created through the Reminders UI **does not appear in
  `Calendar.sqlitedb` at all** - the row count stayed at 135 - yet it persists
  across a relaunch and shows in the app.

So iOS 18 keeps reminders somewhere other than the legacy store, and seeding
that store is writing to a file nothing reads. A previous version of this
directory held a `seed-demo-simulator.py` that did exactly that; it was
removed rather than left to mislead.

## What each connector needs

| Connector | Fixture | How |
| --- | --- | --- |
| `contacts.search` | **Nothing** | The simulator ships Apple's six sample contacts - Kate Bell, Daniel Higgins, John Appleseed, Anna Haro, Hank Zakroff, David Taylor - with 25 phone numbers and emails between them. |
| `device.status` | **Nothing** | Verified returning `online=true lowPower=false`. |
| `photos.latest` | One command | `xcrun simctl addmedia <udid> some.png` |
| `reminders.list` | Reminders app | See below. |
| `calendar.events` | Calendar app | Same idea; add events by hand. |
| `music.*` | Not available | The simulator has no media library. |

`contacts.search` is the connector to demo first: it needs no setup, and
"list all my contacts" being refused is the more interesting story anyway.

## Seeding reminders through the UI

The only method that works. Reminders added this way persist across relaunches
and are what EventKit actually reads.

1. Launch Reminders. Dismiss the welcome screen with **Continue**.
2. Open the **Reminders** list under *My Lists*.
3. Tap **New Reminder** at the bottom left.
4. Type a title and press Return. The editor commits and opens a fresh row, so
   several can be added in one pass without touching the screen again.
5. Tap empty space to dismiss the editor.

Five reminders were added this way in about a minute.

## Driving the simulator from the command line

`idb` is not required. `cliclick` plus `osascript` is enough, with three
things worth knowing:

- **Activate the Simulator first.** Until it is frontmost, System Events
  cannot see its window and lookups fail with `-1719`.
- **Release before clicking**: `cliclick du:x,y w:300 c:x,y`. A stale drag
  leaves iOS showing a text-selection loupe that will ruin a frame.
- **Type with `osascript ... keystroke`, not `cliclick t:`** - the latter
  drops characters at this speed, silently and mid-word.

To map screen coordinates, render the screenshot to logical size and read
coordinates straight off it:

    xcrun simctl io <udid> screenshot shot.png
    ffmpeg -i shot.png -vf "scale=402:874" shot-logical.png   # iPhone 16 Pro

Then, with the window box from
`osascript -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1'`:

    screen_x = window_x + (window_w / 402) * logical_x
    screen_y = window_y + (window_h / 874) * logical_y

This is reliable in the lower two thirds of the screen. Taps near the top
edge, and taps on system alerts, frequently do not register - budget for
retries there or avoid those controls.
