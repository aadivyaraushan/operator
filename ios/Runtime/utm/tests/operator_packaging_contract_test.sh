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

# shellcheck disable=SC1091
. "$UTM_DIR/manifest.env"

PACKAGING_PATCH="$UTM_DIR/overlay/operator-packaging.patch"
OPERATOR_INFO_PLIST="$UTM_DIR/overlay/Operator-Info.plist"
COMPATIBILITY_PATCH="$UTM_DIR/overlay/xcode16-compatibility.patch"
APPLY_SCRIPT="$UTM_DIR/scripts/apply-overlay.sh"
STANDALONE_PROJECT_SPEC="$UTM_DIR/../../project.yml"
STANDALONE_PROJECT="$UTM_DIR/../../Operator.xcodeproj/project.pbxproj"
APP_ICON_CATALOG="$UTM_DIR/../../OperatorApp/Assets.xcassets"
APP_ICON_CONTENTS="$APP_ICON_CATALOG/AppIcon.appiconset/Contents.json"
APP_ICON_PNG="$APP_ICON_CATALOG/AppIcon.appiconset/Operator-AppIcon.png"
[ -f "$PACKAGING_PATCH" ] || fail "Operator packaging patch does not exist"
[ -f "$OPERATOR_INFO_PLIST" ] || fail "Operator Info.plist overlay does not exist"
[ -f "$APP_ICON_CONTENTS" ] || fail "Operator app icon Contents.json does not exist"
[ -f "$APP_ICON_PNG" ] || fail "Operator app icon PNG does not exist"
[ -n "$OPERATOR_PACKAGING_PATCH_SHA256" ] || fail "Operator packaging patch checksum is not pinned"
[ -n "$OPERATOR_INFO_PLIST_SHA256" ] || fail "Operator Info.plist checksum is not pinned"
[ -n "$OPERATOR_APP_ICON_CATALOG_SHA256" ] || fail "Operator app icon catalog checksum is not pinned"
assert_file_contains "$APPLY_SCRIPT" 'verify_sha256 "$OPERATOR_PACKAGING_PATCH_SHA256" "$PACKAGING_PATCH"'
assert_file_contains "$APPLY_SCRIPT" 'verify_sha256 "$OPERATOR_INFO_PLIST_SHA256" "$OPERATOR_INFO_PLIST"'
assert_file_contains "$APPLY_SCRIPT" 'OPERATOR_APP_ICON_CATALOG_SHA256'
assert_file_contains "$APPLY_SCRIPT" 'cp "$OPERATOR_INFO_PLIST" "$SOURCE_ROOT/Platform/iOS/Operator-Info.plist"'
assert_file_contains "$STANDALONE_PROJECT_SPEC" 'PRODUCT_BUNDLE_IDENTIFIER: app.operator.ios'
assert_file_contains "$STANDALONE_PROJECT_SPEC" 'PRODUCT_MODULE_NAME: OperatorApp'
assert_file_contains "$STANDALONE_PROJECT_SPEC" 'PRODUCT_NAME: Operator'
assert_file_contains "$STANDALONE_PROJECT_SPEC" 'path: OperatorApp/Assets.xcassets'
assert_file_contains "$STANDALONE_PROJECT" 'Assets.xcassets in Resources'
assert_file_contains "$APP_ICON_CONTENTS" '"filename" : "Operator-AppIcon.png"'

icon_width=$(/usr/bin/sips -g pixelWidth "$APP_ICON_PNG" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')
icon_height=$(/usr/bin/sips -g pixelHeight "$APP_ICON_PNG" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')
icon_alpha=$(/usr/bin/sips -g hasAlpha "$APP_ICON_PNG" 2>/dev/null | awk '/hasAlpha:/ { print $2 }')
[ "$icon_width" = 1024 ] || fail "Operator app icon width is not 1024 pixels"
[ "$icon_height" = 1024 ] || fail "Operator app icon height is not 1024 pixels"
[ "$icon_alpha" = no ] || fail "Operator app icon must be opaque"
if grep -F -- 'PRODUCT_MODULE_NAME = Operator;' "$PACKAGING_PATCH" >/dev/null; then
    fail "Operator packaging renames UTM's internal Swift module and breaks UTM-Swift.h imports"
fi

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/operator-packaging-contract.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

git clone --quiet --no-checkout /private/tmp/utm-operator-proof "$TEMP_ROOT/utm"
git -C "$TEMP_ROOT/utm" checkout --quiet --detach "$UTM_COMMIT"
"$APPLY_SCRIPT" "$TEMP_ROOT/utm" >/dev/null

PROJECT="$TEMP_ROOT/utm/UTM.xcodeproj/project.pbxproj"
INFO_PLIST="$TEMP_ROOT/utm/Platform/iOS/Operator-Info.plist"
IOS_SE_SOURCES="$TEMP_ROOT/iOS-SE-sources.pbxproj"
IOS_SE_RESOURCES="$TEMP_ROOT/iOS-SE-resources.pbxproj"
COPIED_APP_ICON_CONTENTS="$TEMP_ROOT/utm/Platform/Assets.xcassets/AppIcon.appiconset/Contents.json"
COPIED_APP_ICON_CATALOG="$TEMP_ROOT/utm/Platform/Assets.xcassets/AppIcon.appiconset"
awk '
    /CEA45E24263519B5002FA97D \/\* Sources \*\/ = \{/ { in_sources = 1 }
    in_sources { print }
    in_sources && /^[[:space:]]*};$/ { exit }
' "$PROJECT" >"$IOS_SE_SOURCES"
awk '
    /CEA45F63263519B5002FA97D \/\* Resources \*\/ = \{/ { in_resources = 1 }
    in_resources { print }
    in_resources && /^[[:space:]]*};$/ { exit }
' "$PROJECT" >"$IOS_SE_RESOURCES"

assert_file_contains "$PROJECT" 'PRODUCT_BUNDLE_IDENTIFIER = app.operator.ios;'
assert_file_contains "$PROJECT" 'PRODUCT_MODULE_NAME = UTM;'
assert_file_contains "$PROJECT" 'PRODUCT_NAME = Operator;'
assert_file_contains "$PROJECT" 'INFOPLIST_FILE = Platform/iOS/Operator-Info.plist;'
assert_file_contains "$PROJECT" 'TARGETED_DEVICE_FAMILY = 1;'
include_all_icon_settings=$(grep -F -c 'ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = NO;' "$PROJECT" || true)
[ "$include_all_icon_settings" -eq 2 ] || fail "iOS-SE does not disable inherited alternate app icons in both build configurations"
assert_file_contains "$IOS_SE_RESOURCES" 'Assets.xcassets in Resources'
if grep -F -- 'AppIcon.icon in Resources' "$IOS_SE_RESOURCES" >/dev/null; then
    fail "iOS-SE still packages the Xcode 26-only AppIcon.icon resource"
fi
assert_file_contains "$COPIED_APP_ICON_CONTENTS" '"filename" : "Operator-AppIcon.png"'
source_icon_files=$(cd "$APP_ICON_CATALOG/AppIcon.appiconset" && find . -type f -print | LC_ALL=C sort)
copied_icon_files=$(cd "$COPIED_APP_ICON_CATALOG" && find . -type f -print | LC_ALL=C sort)
[ "$source_icon_files" = "$copied_icon_files" ] || fail "UTM app icon catalog retains files from the inherited UTM icon"
assert_file_contains "$INFO_PLIST" '<key>CFBundleDisplayName</key>'
assert_file_contains "$INFO_PLIST" '<string>Operator</string>'
assert_file_contains "$INFO_PLIST" '<key>NSAllowsLocalNetworking</key>'
assert_file_contains "$INFO_PLIST" '<key>NSMicrophoneUsageDescription</key>'
assert_file_contains "$INFO_PLIST" '<key>NSSpeechRecognitionUsageDescription</key>'
assert_file_contains "$INFO_PLIST" '<key>NSLocationWhenInUseUsageDescription</key>'
if grep -F -- 'NSLocationAlways' "$INFO_PLIST" >/dev/null; then
    fail "Operator Info.plist requests background-capable location permission"
fi
if grep -A8 -F -- '<key>UIBackgroundModes</key>' "$INFO_PLIST" | grep -F -- '<string>location</string>' >/dev/null; then
    fail "Operator Info.plist enables background location"
fi
if grep -F -- 'UISupportedInterfaceOrientations~ipad' "$INFO_PLIST" >/dev/null; then
    fail "Operator Info.plist still advertises an iPad layout"
fi

for inherited_surface in \
    'CFBundleDocumentTypes' \
    'CFBundleURLTypes' \
    'UIBackgroundModes' \
    'UTExportedTypeDeclarations' \
    'UIApplicationSceneManifest' \
    'NSAllowsArbitraryLoads' \
    'com.utmapp' \
    'UTM SE'; do
    if grep -F -- "$inherited_surface" "$INFO_PLIST" >/dev/null; then
        fail "Operator Info.plist retains inherited UTM surface: $inherited_surface"
    fi
done

for intent_build_file in \
    'CE88A1512E2344A900EAA28E /* UTMVirtualMachineEntityQuery.swift in Sources */' \
    'CE88A1612E24B2B400EAA28E /* UTMInputIntent.swift in Sources */' \
    'CE88A1582E247D0100EAA28E /* UTMActionIntent.swift in Sources */' \
    'CE88A1542E247CCE00EAA28E /* UTMIntent.swift in Sources */' \
    'CE88A0A42E2321D200EAA28E /* UTMVirtualMachineEntity.swift in Sources */'; do
    if grep -F -- "$intent_build_file" "$IOS_SE_SOURCES" >/dev/null; then
        fail "iOS-SE still compiles inherited UTM App Intent source: $intent_build_file"
    fi
done

printf 'PASS: Operator packaging contract\n'
