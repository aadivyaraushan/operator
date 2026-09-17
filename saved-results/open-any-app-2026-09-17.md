# Open any app by name (2026-09-17)

What this is for: "open google docs" typed to Operator should open that app.

## How it works
`apps.open` now takes `name`. Steps, in order:
1. Look the name up in `ios/OperatorApp/Resources/connections/handoff/app-links.json`
   (about 60 apps) and try the app's own link (e.g. `googledocs://`).
2. Otherwise get the app's bundle id from that table, or from Apple's free
   iTunes Search API (exact title match only), and open it with
   `LSApplicationWorkspace.openApplicationWithBundleID:`.
3. A name sent as `appID` that is not a known website is treated as a name.

## WARNING before any App Store release
Step 2 uses a private Apple call. App Store review rejects it. Remove
`SystemInstalledAppLauncher.openBundle` (or ship links only) before submitting.
Fine for personal / TestFlight-free installs.

## Verified
- 15 handoff unit tests pass (`AppLaunchByNameTests`, 8 new).
- Real app on the QA Simulator (iOS sim 49A153C3): "open the settings app" ->
  `apps.open` returned ok, Settings came to the front, and the tool result
  was recorded in the transcript (so leaving Operator did not lose it).
- Not verified: a third-party app (none installed on the Simulator), a
  physical iPhone, the iTunes lookup against the live service.

Cost: two short turns on the owner's personal ChatGPT account
(ssdear@gmail.com), approved 2026-09-14.
