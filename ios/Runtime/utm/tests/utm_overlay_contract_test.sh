#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UTM_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_file_contains() {
    file=$1
    text=$2
    grep -F -- "$text" "$file" >/dev/null || fail "$file is missing: $text"
}

[ -f "$UTM_DIR/manifest.env" ] || fail "manifest.env does not exist"
# shellcheck disable=SC1091
. "$UTM_DIR/manifest.env"

[ "$UTM_VERSION" = "4.7.5" ] || fail "UTM_VERSION must be 4.7.5"
[ "$UTM_COMMIT" = "048ca7498ea3a374439149d51739d94c5300bcda" ] || fail "UTM_COMMIT is not pinned"
[ "$UTM_SCHEME" = "iOS-SE" ] || fail "UTM_SCHEME must be iOS-SE"
[ "$UTM_SDK" = "iphoneos" ] || fail "UTM_SDK must be iphoneos"
[ "$UTM_ARCH" = "arm64" ] || fail "UTM_ARCH must be arm64"
[ "$QEMUKIT_COMMIT" = "589765abff27a8764d58b1a90999a204ac09881e" ] || fail "QEMUKIT_COMMIT is not pinned"
[ -n "$QEMUKIT_SNAPSHOT_TIMEOUT_PATCH_SHA256" ] || fail "QEMUKit snapshot timeout patch checksum is not pinned"

APP_OVERLAY="$UTM_DIR/overlay/UTMApp.swift"
APPLY_SCRIPT="$UTM_DIR/scripts/apply-overlay.sh"
BUILD_SCRIPT="$UTM_DIR/scripts/build-unsigned.sh"
QEMUKIT_PATCH_SCRIPT="$UTM_DIR/scripts/apply-qemukit-snapshot-timeout.sh"
SOURCE_LIST="$UTM_DIR/operator-sources.list"
CHAT_SCREEN="$UTM_DIR/../../OperatorApp/Sources/chat/ChatScreen.swift"
node - "$UTM_DIR/../../Operator.xcodeproj/project.pbxproj" "$UTM_DIR/../../OperatorApp/Sources" <<'NODE'
const fs = require('node:fs'), path = require('node:path');
const {execFileSync} = require('node:child_process');
const [project, sourceRoot] = process.argv.slice(2);
const objects = JSON.parse(execFileSync('plutil', ['-convert','json','-o','-',project], {encoding:'utf8'})).objects;
const target = Object.values(objects).find(x => x.isa === 'PBXNativeTarget' && x.name === 'OperatorApp');
if (!target) throw new Error('OperatorApp target missing');
const refs = target.buildPhases.flatMap(id => objects[id].isa === 'PBXSourcesBuildPhase' ? objects[id].files : [])
  .map(id => objects[objects[id].fileRef]).map(x => path.basename(x.path));
function walk(dir) { return fs.readdirSync(dir, {withFileTypes:true}).flatMap(e => e.isDirectory() ? walk(path.join(dir,e.name)) : e.name.endsWith('.swift') ? [e.name] : []); }
const missing = walk(sourceRoot).filter(name => !refs.includes(name));
if (missing.length) throw new Error(`App target omits Swift sources: ${missing.join(', ')}`);
console.log('PASS: standalone target includes every app Swift source');
NODE
STANDALONE_APP="$UTM_DIR/../../OperatorApp/Sources/app/OperatorApp.swift"

[ -f "$APP_OVERLAY" ] || fail "UTMApp.swift overlay does not exist"
[ -f "$SOURCE_LIST" ] || fail "operator-sources.list does not exist"
[ -f "$UTM_DIR/../../OperatorApp/Sources/capabilities/calendar/ForegroundCalendarService.swift" ] || fail "calendar service source does not exist"
[ -f "$UTM_DIR/../../OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift" ] || fail "node router source does not exist"
[ -x "$APPLY_SCRIPT" ] || fail "apply-overlay.sh is not executable"
[ -x "$BUILD_SCRIPT" ] || fail "build-unsigned.sh is not executable"
[ -f "$UTM_DIR/overlay/qemukit-snapshot-timeout.patch" ] || fail "QEMUKit snapshot timeout patch does not exist"
[ -f "$UTM_DIR/overlay/operator-calendar-eventkit.patch" ] || fail "calendar EventKit patch does not exist"
[ -x "$QEMUKIT_PATCH_SCRIPT" ] || fail "QEMUKit snapshot timeout patch script is not executable"
assert_file_contains "$BUILD_SCRIPT" '-target "$UTM_SCHEME"'
assert_file_contains "$BUILD_SCRIPT" '-configuration Debug'
assert_file_contains "$BUILD_SCRIPT" '-clonedSourcePackagesDirPath "$SOURCE_PACKAGES"'
assert_file_contains "$BUILD_SCRIPT" 'apply-qemukit-snapshot-timeout.sh" "$SOURCE_PACKAGES"'
assert_file_contains "$BUILD_SCRIPT" 'CODE_SIGNING_ALLOWED=NO'
assert_file_contains "$BUILD_SCRIPT" 'ONLY_ACTIVE_ARCH=YES'
assert_file_contains "$BUILD_SCRIPT" 'IPHONEOS_DEPLOYMENT_TARGET=18.0'
assert_file_contains "$BUILD_SCRIPT" 'CLANG_MODULE_CACHE_PATH="$OUTPUT_ROOT/module-cache"'

assert_file_contains "$APP_OVERLAY" 'Bundle.main.url(forResource: guestResourceName, withExtension: "utm")'
assert_file_contains "$APP_OVERLAY" 'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)'
assert_file_contains "$APP_OVERLAY" 'values.isExcludedFromBackup = true'
assert_file_contains "$APP_OVERLAY" 'try writableURL.setResourceValues(values)'
assert_file_contains "$APP_OVERLAY" '.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication'
assert_file_contains "$APP_OVERLAY" 'func protectWritableGuest(at packageURL: URL) throws'
assert_file_contains "$APP_OVERLAY" 'FileManager.default.subpathsOfDirectory(atPath: packageURL.path)'
assert_file_contains "$APP_OVERLAY" 'UTMQemuConfiguration.load(from: packageURL)'
assert_file_contains "$APP_OVERLAY" 'UTMQemuVirtualMachine(packageUrl: packageURL, configuration: configuration)'
assert_file_contains "$APP_OVERLAY" 'try await virtualMachine.start(options: [])'
assert_file_contains "$APP_OVERLAY" 'try await virtualMachine.saveSnapshot(name: nil)'
assert_file_contains "$APP_OVERLAY" 'try await virtualMachine.pause()'
assert_file_contains "$APP_OVERLAY" 'try await virtualMachine.resume()'
if grep -F 'virtualMachine.stop(' "$APP_OVERLAY" >/dev/null; then
    fail "Operator still tears down QEMU instead of pausing or reconnecting"
fi
assert_file_contains "$APP_OVERLAY" 'name=opt/openclaw/gateway-token,file=\(fileURLs.gatewayToken.path)'
assert_file_contains "$APP_OVERLAY" 'name=opt/openclaw/device-id,file=\(fileURLs.deviceID.path)'
assert_file_contains "$APP_OVERLAY" 'name=opt/openclaw/device-public-key,file=\(fileURLs.devicePublicKey.path)'
assert_file_contains "$APP_OVERLAY" 'try FileManager.default.setAttributes([.posixPermissions: 0o700]'
assert_file_contains "$APP_OVERLAY" 'try FileManager.default.setAttributes([.posixPermissions: 0o600]'
assert_file_contains "$APP_OVERLAY" 'defer {'
assert_file_contains "$APP_OVERLAY" 'launchFiles.delete()'
assert_file_contains "$APP_OVERLAY" 'virtualMachine.config.qemu.additionalArguments = originalArguments'
assert_file_contains "$APP_OVERLAY" 'GatewayInstallationVault(store: credentialStore)'
assert_file_contains "$APP_OVERLAY" 'OperatorLaunchCredentials('
assert_file_contains "$APP_OVERLAY" 'credentials.identity.deviceID'
assert_file_contains "$APP_OVERLAY" 'actions.contains(.restoreSnapshot)'
assert_file_contains "$APP_OVERLAY" 'await self.setup.check()'
assert_file_contains "$APP_OVERLAY" 'await self.vm.saveSnapshot()'
assert_file_contains "$APP_OVERLAY" 'try await self.reconnectAfterModelSetup()'
assert_file_contains "$APP_OVERLAY" 'UTMRegistry.shared.sync()'
sync_count=$(grep -F -c 'UTMRegistry.shared.sync()' "$APP_OVERLAY")
[ "$sync_count" -eq 3 ] || fail "expected registry sync after start, paused resume and snapshot save, found $sync_count"
assert_file_contains "$APP_OVERLAY" 'ChatScreen(model: self.runtime.chat, setup: self.runtime.setup, whatsapp: self.runtime.whatsapp)'
assert_file_contains "$APP_OVERLAY" 'WhatsAppLinkFlowModel(gateway: WhatsAppLinkGatewayClient('
assert_file_contains "$CHAT_SCREEN" 'WhatsAppLinkSheet(model: self.whatsapp)'
assert_file_contains "$UTM_DIR/../../Operator.xcodeproj/project.pbxproj" 'WhatsAppLinkFlow.swift in Sources'
assert_file_contains "$UTM_DIR/../../Operator.xcodeproj/project.pbxproj" 'WhatsAppLinkSheet.swift in Sources'
assert_file_contains "$UTM_DIR/../../OperatorApp/Sources/app/OperatorApp.swift" 'ChatScreen(model: self.chat, setup: self.setup, whatsapp: self.whatsapp)'
assert_file_contains "$APP_OVERLAY" 'if self.scenePhase != .active {'
assert_file_contains "$APP_OVERLAY" 'OperatorPrivacyCover()'
assert_file_contains "$CHAT_SCREEN" 'self.model.restore()'
if grep -F 'setForegroundActive' "$CHAT_SCREEN" >/dev/null; then
    fail "ChatScreen must leave runtime foreground ownership to its host"
fi
assert_file_contains "$STANDALONE_APP" 'let platform = "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"'
assert_file_contains "$SOURCE_LIST" 'ios/OperatorApp/Sources/capabilities/calendar/ForegroundCalendarService.swift'
assert_file_contains "$SOURCE_LIST" 'ios/OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift'
assert_file_contains "$APP_OVERLAY" 'handler: ForegroundNodeCommandRouter('
assert_file_contains "$APP_OVERLAY" 'messages: ForegroundMessageComposeService('
assert_file_contains "$STANDALONE_APP" 'messages: ForegroundMessageComposeService('
assert_file_contains "$SOURCE_LIST" 'ios/OperatorApp/Sources/capabilities/messages/ForegroundMessageComposeService.swift'
assert_file_contains "$SOURCE_LIST" 'ios/OperatorApp/Sources/capabilities/messages/SystemMessageComposer.swift'
assert_file_contains "$APP_OVERLAY" 'calendar: ForegroundCalendarService()'

if grep -F 'UTMSingleWindowView' "$APP_OVERLAY" >/dev/null; then
    fail "consumer overlay exposes the UTM library UI"
fi
if grep -F 'VMCommands' "$APP_OVERLAY" >/dev/null; then
    fail "consumer overlay exposes UTM VM commands"
fi
if grep -F 'TabView' "$APP_OVERLAY" >/dev/null; then
    fail "consumer overlay contains a tab-based root"
fi
if grep -F 'Form {' "$APP_OVERLAY" >/dev/null; then
    fail "consumer overlay contains the VM control form"
fi

fw_cfg_flag_count=$(grep -F -c 'QEMUArgument("-fw_cfg")' "$APP_OVERLAY")
[ "$fw_cfg_flag_count" -eq 3 ] || fail "expected exactly three -fw_cfg QEMU arguments, found $fw_cfg_flag_count"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/operator-utm-contract.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

git -C "$UTM_DIR" rev-parse --show-toplevel >/dev/null 2>&1 || fail "tests must run from a git checkout"
git clone --quiet --no-checkout /private/tmp/utm-operator-proof "$TEMP_ROOT/utm"
git -C "$TEMP_ROOT/utm" checkout --quiet --detach "$UTM_COMMIT"

"$APPLY_SCRIPT" "$TEMP_ROOT/utm"
GENERATED_APP="$TEMP_ROOT/utm/Platform/iOS/UTMApp.swift"
assert_file_contains "$GENERATED_APP" 'public actor ConversationStore'
assert_file_contains "$GENERATED_APP" 'public actor GatewayInstallationVault'
assert_file_contains "$GENERATED_APP" 'final class ChatSessionModel: ObservableObject'
assert_file_contains "$GENERATED_APP" 'struct ChatScreen: View'
assert_file_contains "$GENERATED_APP" 'final class ModelSetupModel: ObservableObject'
assert_file_contains "$GENERATED_APP" 'import AVFAudio'
assert_file_contains "$GENERATED_APP" 'import CoreLocation'
assert_file_contains "$GENERATED_APP" 'import EventKit'
assert_file_contains "$GENERATED_APP" 'import MessageUI'
assert_file_contains "$GENERATED_APP" 'final class SystemMessageComposer'
assert_file_contains "$GENERATED_APP" 'messages: ForegroundMessageComposeService('
assert_file_contains "$GENERATED_APP" 'import Speech'
assert_file_contains "$GENERATED_APP" 'final class ForegroundLocationService'
assert_file_contains "$GENERATED_APP" 'final class ForegroundCalendarService'
assert_file_contains "$GENERATED_APP" 'final class ForegroundNodeCommandRouter'
assert_file_contains "$GENERATED_APP" 'actor LocalLocationNodeGateway'
assert_file_contains "$GENERATED_APP" 'public actor OpenClawNodeConnection'
assert_file_contains "$GENERATED_APP" 'struct UTMApp: App'
assert_file_contains "$GENERATED_APP" 'ChatScreen(model: self.runtime.chat, setup: self.runtime.setup, whatsapp: self.runtime.whatsapp)'
assert_file_contains "$GENERATED_APP" 'final class WhatsAppLinkFlowModel'
assert_file_contains "$GENERATED_APP" 'struct WhatsAppLinkSheet'
assert_file_contains "$GENERATED_APP" 'private var isRuntimeReady = false'
assert_file_contains "$GENERATED_APP" 'while self.isRuntimeReady, self.isForegroundActive, !Task.isCancelled'
assert_file_contains "$GENERATED_APP" 'await self.locationNode.start()'
assert_file_contains "$GENERATED_APP" 'await self.locationNode.stop()'
assert_file_contains "$GENERATED_APP" 'handler: ForegroundNodeCommandRouter('
assert_file_contains "$GENERATED_APP" 'calendar: ForegroundCalendarService()'
assert_file_contains "$TEMP_ROOT/utm/UTM.xcodeproj/project.pbxproj" 'EventKit.framework in Frameworks'
assert_file_contains "$TEMP_ROOT/utm/UTM.xcodeproj/project.pbxproj" 'name = EventKit.framework; path = System/Library/Frameworks/EventKit.framework; sourceTree = SDKROOT;'
calendar_usage=$(plutil -extract NSCalendarsFullAccessUsageDescription raw -o - "$TEMP_ROOT/utm/Platform/iOS/Operator-Info.plist")
[ "$calendar_usage" = 'Operator reads your calendar only when you ask the agent for upcoming events.' ] || fail "calendar privacy description is missing or changed"

standalone_node_init=$(awk '/let locationNode = LocalLocationNodeGateway\(/,/isAppActive:.*\)\)\)/ { print }' "$STANDALONE_APP")
printf '%s\n' "$standalone_node_init" | grep -F -- 'platform: platform' >/dev/null || fail "standalone node does not use the shared runtime platform"
generated_node_init=$(awk '/self.locationNode = LocalLocationNodeGateway\(/,/isAppActive:.*\)\)\)/ { print }' "$GENERATED_APP")
printf '%s\n' "$generated_node_init" | grep -F -- 'platform: platform' >/dev/null || fail "generated node does not use the shared runtime platform"

start_line=$(grep -n -F 'guard await self.vm.start(credentials: launchCredentials)' "$GENERATED_APP" | head -1 | cut -d: -f1)
setup_line=$(grep -n -F 'await self.setup.check()' "$GENERATED_APP" | head -1 | cut -d: -f1)
[ "$setup_line" -gt "$start_line" ] || fail "model setup check is not after VM start"
if grep -F 'import OperatorCore' "$GENERATED_APP" >/dev/null; then
    fail "generated same-module source still imports OperatorCore"
fi
if grep -F 'struct OperatorApp: App' "$GENERATED_APP" >/dev/null; then
    fail "generated source retained the standalone OperatorApp declaration"
fi
if grep -F 'UTMSingleWindowView' "$GENERATED_APP" >/dev/null; then
    fail "generated app exposes the UTM library UI"
fi
sh "$SCRIPT_DIR/runtime-gate/run.sh" "$GENERATED_APP"
"$APPLY_SCRIPT" "$TEMP_ROOT/utm"

git clone --quiet --no-checkout /private/tmp/utm-operator-proof "$TEMP_ROOT/wrong-utm"
git -C "$TEMP_ROOT/wrong-utm" checkout --quiet --detach "$UTM_COMMIT"
git -C "$TEMP_ROOT/wrong-utm" -c user.name=contract-test -c user.email=contract-test.invalid commit --quiet --allow-empty -m wrong-commit
if "$APPLY_SCRIPT" "$TEMP_ROOT/wrong-utm" >"$TEMP_ROOT/wrong-commit.out" 2>&1; then
    fail "overlay accepted a source tree at the wrong commit"
fi
assert_file_contains "$TEMP_ROOT/wrong-commit.out" "expected UTM commit $UTM_COMMIT"

printf 'PASS: UTM overlay contract\n'
