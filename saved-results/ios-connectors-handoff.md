# Operator iPhone — connector developer handoff

Updated September 10, 2026. This is the starting point for the next developer, not a claim that the connections are finished.

## Start here

- Repository: https://github.com/aadivyaraushan/operator (the old `codex-launcher` remote redirects here).
- Branch: `codex/ios-operator`. Do not use `main` for this handoff.
- Scope: iPhone only. Android is unchanged by this work.
- Architecture: SwiftUI chat → **embedded NodeMobile + actual OpenClaw** → native Swift/Go phone tools and direct service APIs. No Linux VM or Mac/cloud gateway in the current app.
- Product: one persistent chat, minimal setup, saved history and drafts. Do not add a session-management-heavy interface.
- First priority: finish a real Google sign-in and read through Operator; then work through the other accounts. Do not mistake registration/configuration or fixture tests for a working account connection.

```sh
git clone --branch codex/ios-operator https://github.com/aadivyaraushan/operator.git
cd operator
```

## What is implemented, and what remains

The “observed” column below describes September 9 evidence from the original Mac. These live results were not repeated on September 10 or on a clean machine.

| Connection | Implemented / observed | Remaining |
| --- | --- | --- |
| Google Calendar / Drive | Native browser sign-in, refresh/token storage, Calendar event reads, Drive file search, confirmed event/file creation. Public iOS registration is configured. | Google returned **Try again** after an earlier login. A callback-parser repair was installed, but the next attempt had not completed. Prove sign-in, a real read, reopen and refresh. `drive.file` is limited access, not access to every Drive file. |
| Microsoft Outlook | Existing registration has a new iOS callback. Read inbox, create draft and confirmed send routes exist. Token validation now separates API permissions from sign-in metadata. | Complete personal-account authorization; verify a read and saved sign-in. No live send test has been performed. |
| Slack | Separate **Operator iPhone** registration, secretless mobile PKCE sign-in, refresh, channel/history reads and confirmed message route. | Authorize from Operator, not a dashboard Install button; prove reads and refresh. Do not alter the Android/shared Slack registration. |
| Spotify | Existing registration, phone-local loopback callback, search/current-playback reads, confirmed playback route. | Complete login and read-only checks. Playback was not started as a test. The newer callback fix still needs installation on the original Simulator. |
| Notion | Direct Notion MCP, dynamic client registration, phone-local callback, tool discovery/calls and confirmation for changes. Saved-connection restoration and refresh-overlap fixes are implemented and tested. | Real registration/authorization, read and reopening remain unverified. Latest restoration changes were built, but not installed over the open Google login. |
| WhatsApp | Actual `wacli` is compiled into an in-process Go archive; native link/read/send bridges exist. No Linux executable or Beeper service. Not-linked response and cancelled send preview were exercised. | Owner QR/device linking, real sync/read and interruption recovery. Same-phone linking and physical-device behavior are unverified. Do not send external test messages. |
| Internet | Actual OpenClaw web fetch returned Example Domain through chat. | Check required search flows independently; opening Safari is not equivalent to web research. No Android browser-automation feature was proven to port. |
| Maps / location | Native location/Maps routes; a Millennium Park lookup returned through the app. | Check permissions and physical-device behavior as needed. |
| Device calendar / Messages | EventKit calendar route and owner-controlled message composer. | Permission/real-device checks. Messages is composition only, not inbox access; the user presses Send. |
| App opening | Catalog of Android app IDs mapped to iOS/web destinations; a public site was opened. Results distinguish opening from completing an action. | Validate desired destinations individually. Never claim a purchase/message happened because an app opened. |
| Podcasts | Public RSS lookup returned a real NPR episode. | Additional feed/device checks if required; no playback test was performed. |
| YouTube | Exact-video opening and search implementation exist. Search accurately reports missing credentials. | Configure the search API key securely and prove a search. Existing Google project has a YouTube-restricted key, but suitability/value were not verified or transferred. No in-app key-entry UI yet. |

### Explicit exclusions — do not reintroduce

- No Beeper service integrations, Instagram messaging bridge or personal Discord automation/self-bot.
- No unrestricted iMessage inbox or Android-style notification listening/replies.
- Todoist and Teams were skipped placeholders in the Android production wiring, not completed connectors to port.
- No silent Mac/cloud relay as a substitute for phone-local OpenClaw.

## Sign-in blocker and the latest fixes

The earlier Google failure logged only `PhoneOAuthError`, so its exact cause is **not proven**. A reproducible callback-parser problem rejected extra response fields such as `scope`, `authuser` and `prompt`. The fix accepts unknown response fields while preserving redirect/state validation and duplicate-sensitive-field checks. Failures now log a safe error-case name, without authorization codes, tokens or full callback URLs.

The last observed Simulator was still on Google's empty email field. Do not assume that is still its state: inspect it first. If sign-in now returns Try again, capture the current safe error before restarting anything:

```sh
xcrun simctl list devices booted
# Replace SIMULATOR_UDID with the relevant booted device ID.
xcrun simctl spawn SIMULATOR_UDID log show --last 10m --style compact \
  --predicate 'subsystem == "app.operator.ios" AND category == "phone-oauth"'
```

Other fixes already in source:

- Explicit `OperatorApp/Info.plist`: generated settings had omitted required callback/config/privacy fields. Do not switch back to generated plist without hosted tests.
- Microsoft API-scope validation does not require `openid` / `offline_access` to appear as API token scopes.
- Shared Spotify/Notion loopback callback accepts extension fields and handles denial promptly, while enforcing exact local host/port/path/state.
- Notion restoration checks saved credentials without opening the browser. Account restoration runs separately from chat startup.
- A delayed Notion token refresh must not overwrite credentials from a newer sign-in. Regression test: `testDelayedRefreshPreservesNewAuthorizationStateAndCompletedCredentials`.

## Public registrations

These are public client identifiers, **not credentials**. Actual tokens stay in the app's Keychain. Obtain developer-console access from the owner; do not ask them to send passwords or tokens in chat.

| Provider | Existing configuration |
| --- | --- |
| Google | Project `operator-504223`; iOS client `914186874774-h53ibiefs116cgg1hnrllfhn7f9cscc9.apps.googleusercontent.com`; bundle `app.operator.ios`; callback `com.googleusercontent.apps.914186874774-h53ibiefs116cgg1hnrllfhn7f9cscc9:/oauth2redirect`. Testing mode; test-user restrictions apply. |
| Microsoft | Client `ed4e4e74-ad37-4ddf-a4ca-59d3731be5e6`; callback `msauth.app.operator.ios://auth`; personal Microsoft accounts. Existing Android callbacks were retained. |
| Slack | iPhone app `A0C0LS6HLJX`; client `11647883346533.12020890598643`; callback `app.operator.ios://oauth/slack`; permanent PKCE enabled with owner approval. User scopes: `chat:write channels:read channels:history groups:read groups:history im:write im:history users:read`. No bot scopes. |
| Spotify | Client `2c348c954be24bf68d3680f206625ccd`; callback `http://127.0.0.1:43827/spotify/callback`; development-mode restrictions apply. |
| Notion | `https://mcp.notion.com`; dynamic client registration, authorization code with PKCE, no embedded client secret. |

YouTube's existing storage contract is Keychain service `app.operator.ios.media`, account `youtube-api-key`, raw UTF-8 key bytes (maximum 4096). Do not put the key in source, plist, this handoff or logs. Public client IDs do not grant the next developer console/account access.

## Code map

Paths below are relative to the repository root.

| Area | Start here |
| --- | --- |
| App assembly / foreground restoration | `ios/OperatorApp/Sources/app/OperatorApp.swift` |
| Native OpenClaw bridge | `ios/OperatorApp/Sources/runtime/embedded/`, `ios/Runtime/native-node/` |
| Chat persistence / gateway | `ios/OperatorCore/Sources/OperatorCore/` |
| Tool routing and safety policy | `ios/OperatorApp/Sources/capabilities/node/` |
| Account sign-in and UI | `ios/OperatorApp/Sources/connections/auth/`, `connections/setup/` |
| Account discovery | `ios/OperatorApp/Sources/connections/discovery/` |
| Direct account reads / writes / confirmation | `ios/OperatorApp/Sources/connections/services/` |
| Notion and shared local callback | `ios/OperatorApp/Sources/connections/notion/` |
| WhatsApp native bridges | `ios/Runtime/native-whatsapp/`, `ios/OperatorApp/Sources/capabilities/whatsapp/` |
| YouTube / podcasts | `ios/OperatorApp/Sources/connections/media/` |
| Maps / Messages / app opening | `ios/OperatorApp/Sources/capabilities/` |
| Build/configuration | `ios/project.yml`, `ios/Operator.xcodeproj/`, `ios/OperatorApp/Info.plist` |

The old `ios/Runtime/guest/` and `ios/Runtime/utm/` code is retained historical work, **not the current app's execution path**. Do not restart the Linux architecture from those scripts.

## Next steps, in order

1. Build the current source with the pinned native dependencies below. On the original Mac, inspect any active login before installing. Do not erase the Simulator or replace its private data.
2. Finish Google authorization; verify a small Calendar or permitted Drive read through Operator. If it fails, diagnose the new error rather than repeating login blindly.
3. Authorize Outlook, Slack, Spotify and Notion in the app, one at a time. Verify an actual read from each. An empty-but-successful account result is acceptable evidence; a fixture or stored token alone is not.
4. Reopen the app and prove connection restoration, refresh, and preservation of history/unsent drafts. Check the newer Notion and loopback fixes interactively.
5. Coordinate WhatsApp linking and secure YouTube key setup with the owner; prove reads without sending messages or starting playback.
6. Keep a per-connector evidence table. Only mark the work complete after the agreed supported connections genuinely work. Physical iPhone/background/App Store readiness is a separate, unproven stage.

No live write tests were authorized for this verification run: do not send messages/mail, create account files/events or start playback merely to test. Write/confirmation code has fixture and cancellation evidence only. Ask the owner before any new real external action or billing change.

## Build and test prerequisites

The source is being shared, not the original machine's SDKs, generated libraries, model/account credentials or multi-gigabyte runtime state. A clone alone is **not** a ready-built app. The current target is arm64 iOS Simulator, minimum iOS 18; the development device used was iPhone 14 Pro on iOS 18.6. Physical-device packaging is not proven.

### Native dependencies (not included in Git)

1. Obtain the **full**, not lite, `NodeMobile.xcframework` from [gmaclennan/nodejs-mobile v24.18.0-0](https://github.com/gmaclennan/nodejs-mobile/releases/tag/v24.18.0-0), asset `nodejs-mobile-ios-24.18.0-0.zip`. Put the framework at `ios/build/native-node/NodeMobile.xcframework`. The release describes arm64 device/Simulator slices; the local framework's plist confirms those slices. This is a prerelease dependency. There is no repository download script or pinned framework checksum yet—record/verify the artifact when obtaining it.
2. Obtain the public `openclaw@2026.9.1` package **with its dependencies installed**, in a separate dependency directory. Supply that package's directory (containing `package.json`, `dist`, `node_modules` and `docs/reference/templates`) to the checked-in staging script. It applies the two current compatibility changes and copies the native entry files:

```sh
mkdir -p ios/build/native-node
node ios/Runtime/native-node/package/run.mjs \
  /path/to/openclaw-2026.9.1-package ios/build/native-node/runtime
```

3. Obtain the [wacli v0.17.1 source](https://github.com/openclaw/wacli/releases/tag/v0.17.1), not its macOS/Linux executable. With Xcode tools and Go available:

```sh
bash ios/Runtime/native-whatsapp/archive/build.sh \
  /path/to/pinned-wacli-source ios/build/native-whatsapp
```

The script enforces Go `1.26.6`, module `github.com/openclaw/wacli`, go.mod SHA256 `b751d50a2f8bdd9b3cfc47fe8d3aa017a16c77b87f044b150493656177352116`, and source-tree SHA256 `188bda00ba7e15d32ba78d81ef8b1463b784408eef2d909db32d9d1d5361ba39`. It generates `libWacliBridge.a` for arm64 **Simulator**, not a physical iPhone. If the public source tree fails the pin, investigate the archive contents; do not bypass the check. Both staging scripts refuse to overwrite an existing output directory.

**Reproducibility limit:** these are the source scripts and dependency requirements verified during this handoff, not a newly executed clean-clone bootstrap. A fully automated, checksum-pinned dependency setup remains work for the next developer. Do not copy the original user's runtime/session directory as a shortcut.

### Build the current app

Run from the repository root after the three generated inputs above exist:

```sh
xcodebuild -quiet -project ios/Operator.xcodeproj -scheme OperatorApp \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath /private/tmp/operator-native-integrated-build \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  ONLY_ACTIVE_ARCH=YES IPHONEOS_DEPLOYMENT_TARGET=18.0 build
```

Keep Simulator signing enabled: the app uses Keychain. The checked-in Xcode project is present; `ios/project.yml` is its XcodeGen source. Do not use the old UTM build scripts for this app.

After the build finishes successfully, install and launch in order, using your own Simulator ID. On the original Mac, first check that no account login is active and preserve the existing app data. Do **not** uninstall or erase the device.

```sh
xcrun simctl install SIMULATOR_UDID \
  /private/tmp/operator-native-integrated-build/Build/Products/Debug-iphonesimulator/Operator.app
xcrun simctl launch SIMULATOR_UDID app.operator.ios
```

### Tests

The connector fixture suites run on the Mac without service accounts:

```sh
swift test --package-path ios/OperatorCore
for suite in auth read write media discovery confirmation setup notion notion-node notion-callback spotify-loopback; do
  bash "ios/OperatorApp/Tests/connections/$suite/run.sh" || exit 1
done
```

Hosted iOS tests are still needed to check the actual app bundle's registration settings; the Mac setup fixture cannot substitute for those. The earlier hosted configuration run passed 10 tests, but it was not rerun for this handoff. Earlier full app build/signing also passed; neither a clean-machine build nor live account tests are being claimed here.

Fresh September 10 checks:

- Native Node tests: **22 passed, 0 failed**, exit 0. Reproduce with:

```sh
node --test ios/Runtime/native-node/tests/package/stage.test.mjs \
  ios/Runtime/native-node/tests/state/state.test.mjs \
  ios/Runtime/native-node/tests/state/bootstrap.test.mjs \
  ios/Runtime/native-node/tests/host/start.test.mjs \
  ios/Runtime/native-node/compat/sqlite/tests/ownership.test.mjs \
  ios/Runtime/native-node/compat/lifecycle/tests/export.test.mjs
```

- `plutil -lint ios/OperatorApp/Info.plist ios/OperatorWidget/Info.plist ios/Operator.xcodeproj/project.pbxproj`: all three OK, exit 0.
- Staged whitespace check excluding historical `*.patch` files: exit 0. The full check reports context whitespace in those patches; they were preserved rather than changed. Source/configuration files pass.
- Swift connector fixtures: **101 tests passed**, all 11 script exits 0: auth 14, notion 15, notion-node 9, notion-callback 7, spotify-loopback 6, read 9, write 9, media 17, discovery 4, confirmation 6, setup 5.
- `swift test --package-path ios/OperatorCore`: **70 tests passed, 0 failures**, exit 0. SwiftPM emitted an unhandled-fixture-resource warning. These Mac fixtures do not establish live provider access.
