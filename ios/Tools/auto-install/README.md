# Auto-install: main → your iPhone

Keeps a paired iPhone on the newest commit of `main`, like Vercel keeps a
site on the newest push, without the paid Apple Developer Program.

## How it works

```
push to main ──▶ Mac job (every 5 min) ──▶ new commit or install >6 days old?
                                                  │ yes
                                                  ▼
                              clean checkout ─▶ xcodebuild (free profile) ─▶ devicectl install over Wi‑Fi
                                                  │ any step fails
                                                  ▼
                                          Mac notification + deploy.log
```

## One-time setup (on the Mac that will do the builds)

1. Xcode → Settings → Accounts → add your Apple ID. A free "Personal Team"
   is enough. This creates the Apple Development certificate the script
   looks for; nothing to type into a config file.
2. On the iPhone: Settings → Privacy & Security → Developer Mode → on
   (the phone restarts).
3. Plug the phone into the Mac once, tap Trust. Check it is listed:
   `xcrun devicectl list devices`.
4. Register the job:
   ```
   OPERATOR_AUTO_INSTALL_BRANCH=<branch> ios/Tools/auto-install/install.sh
   ```
   It runs a first build and install straight away.

## Every day

Merge to `main`, wait a few minutes, open Operator.

- `deploy.sh now` builds and installs right now, ignoring the poll.
- `deploy.sh status` shows what commit is on the phone and when.
- `deploy.sh tick` is what launchd runs.
- Log: `~/Library/Application Support/Operator/auto-install/deploy.log`.
- `install.sh remove` stops the job.

## Limits

- The Mac has to be awake. Lid closed usually means asleep.
- The phone has to be on the same network as the Mac (or plugged in) when
  the install runs; otherwise it retries on the next tick.
- Free-profile builds stop launching after 7 days, so the same build is
  reinstalled on day 6 even if `main` has not moved. The Mac and phone
  need to meet at least weekly.
- Only phones paired to this Mac. Your logins and chats survive updates;
  only deleting the app wipes them.

## Tests

`test.sh` runs `deploy.sh` against stubbed `git`, `xcodebuild`, `xcrun`,
`security` and `osascript` and checks every decision: first install, no
change, forced, 6-day reinstall, failed build, missing certificate.
