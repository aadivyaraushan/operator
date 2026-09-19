# One tap into Operator from the Lock Screen (2026-09-18)

## Why
Operator positions itself as the thing the phone opens into. iOS does not
let an app replace the Home Screen, so the closest legal path is a Lock
Screen widget plus an iOS 18 Control (Action button / Lock Screen bottom
buttons / Control Center). See `ios/OperatorWidget/Sources/OperatorWidget.swift`.

## What changed
- Widget now draws the brand mark (large vermilion disc, smaller rust disc
  below-left) instead of an SF "message" icon. Lock Screen renders it in the
  system tint; Home Screen gets real colours on near-black.
- New `OpenOperatorControl` (ControlWidget) with `OpenOperatorIntent`
  (`openAppWhenRun = true`). Users find it under "Operator" in the Controls
  gallery and can assign it to the Action button or a Lock Screen button.
- Contract test `ios/OperatorWidgetTests/operator_widget_contract_test.sh`
  was failing before this change on a stale literal
  (`app.operator.ios.widget`; project.yml uses `$(OPERATOR_BUNDLE_ID_PREFIX)`).
  Fixed, and it now checks the Control exists.

## Verified on the QA Simulator (iPhone 14 Pro, 49A153C3-…)
- `xcodebuild -target OperatorWidget -sdk iphonesimulator` → BUILD SUCCEEDED.
- Contract test → `PASS: Operator widget contract`.
- Full app build, installed over the existing app (logins kept).
- Lock Screen → Customize → Add Widgets lists Operator with both shapes;
  the circular one was added, Done, then tapped from the real lock screen:
  the chat opened with history intact.
- The Control appears in the Lock Screen button picker under "Operator ›
  Open Operator" and could be placed on the bottom-right slot. The simulator
  does not draw the bottom buttons on its lock screen, so the Control's tap
  was not exercised; do that on the real phone.

## Not done / limits
- No real-device run yet (Mac cannot sign phone builds; see
  `saved-results`-adjacent memory `iphone-auto-install-setup`).
- Apple docs for ControlWidget were not re-read this session (Context7 has
  no Apple docs); the API shape is verified by the compiler only.

## Reproduce
```
cd ios
xcodebuild -project Operator.xcodeproj -target OperatorWidget -sdk iphonesimulator -configuration Debug SYMROOT=/tmp/op-widget build
sh OperatorWidgetTests/operator_widget_contract_test.sh /tmp/op-widget/Debug-iphonesimulator/OperatorWidget.appex
```
Then build the OperatorApp scheme for the simulator, `simctl install`, lock
the simulator, long-press → Customize → Lock Screen → Add Widgets → Operator.
