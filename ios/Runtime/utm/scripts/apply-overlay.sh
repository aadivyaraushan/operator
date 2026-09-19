#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UTM_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$UTM_DIR/manifest.env"

usage() {
    printf 'Usage: %s /path/to/UTM-source\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
SOURCE_ROOT=$1
[ -d "$SOURCE_ROOT/.git" ] || {
    printf 'error: %s is not a UTM git checkout\n' "$SOURCE_ROOT" >&2
    exit 2
}

actual_commit=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
[ "$actual_commit" = "$UTM_COMMIT" ] || {
    printf 'error: expected UTM commit %s, found %s\n' "$UTM_COMMIT" "$actual_commit" >&2
    exit 2
}

verify_sha256() {
    expected=$1
    file=$2
    actual=$(/usr/bin/shasum -a 256 "$file" | awk '{print $1}')
    [ "$actual" = "$expected" ] || {
        printf 'error: checksum mismatch for %s\n' "$file" >&2
        exit 2
    }
}

PROJECT_ROOT=$(CDPATH= cd -- "$UTM_DIR/../../.." && pwd)
APP_OVERLAY="$UTM_DIR/overlay/UTMApp.swift"
COMPATIBILITY_PATCH="$UTM_DIR/overlay/xcode16-compatibility.patch"
PACKAGING_PATCH="$UTM_DIR/overlay/operator-packaging.patch"
CALENDAR_EVENTKIT_PATCH="$UTM_DIR/overlay/operator-calendar-eventkit.patch"
OPERATOR_INFO_PLIST="$UTM_DIR/overlay/Operator-Info.plist"
SOURCE_LIST="$UTM_DIR/operator-sources.list"
APP_ICON_CATALOG="$PROJECT_ROOT/ios/OperatorApp/Assets.xcassets/AppIcon.appiconset"
verify_sha256 "$OPERATOR_APP_OVERLAY_SHA256" "$APP_OVERLAY"
verify_sha256 "$XCODE16_PATCH_SHA256" "$COMPATIBILITY_PATCH"
verify_sha256 "$OPERATOR_PACKAGING_PATCH_SHA256" "$PACKAGING_PATCH"
verify_sha256 "$OPERATOR_CALENDAR_EVENTKIT_PATCH_SHA256" "$CALENDAR_EVENTKIT_PATCH"
verify_sha256 "$OPERATOR_INFO_PLIST_SHA256" "$OPERATOR_INFO_PLIST"

[ -f "$SOURCE_LIST" ] || {
    printf 'error: Operator source list is missing: %s\n' "$SOURCE_LIST" >&2
    exit 2
}

[ -d "$APP_ICON_CATALOG" ] || {
    printf 'error: Operator app icon catalog is missing: %s\n' "$APP_ICON_CATALOG" >&2
    exit 2
}

actual_app_icon_catalog_sha256=$(
    cd "$APP_ICON_CATALOG"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r relative_path; do
        file_sha256=$(/usr/bin/shasum -a 256 "$relative_path" | awk '{print $1}')
        printf '%s  %s\n' "$file_sha256" "$relative_path"
    done | /usr/bin/shasum -a 256 | awk '{print $1}'
)
[ "$actual_app_icon_catalog_sha256" = "$OPERATOR_APP_ICON_CATALOG_SHA256" ] || {
    printf 'error: Operator app icon catalog checksum mismatch\n' >&2
    exit 2
}

listed_sources=$(sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$SOURCE_LIST")
discovered_sources=$(
    cd "$PROJECT_ROOT"
    find ios/OperatorCore/Sources ios/OperatorApp/Sources -type f -name '*.swift' -print | LC_ALL=C sort
)
[ "$listed_sources" = "$discovered_sources" ] || {
    printf 'error: operator-sources.list does not match the production Swift sources\n' >&2
    exit 2
}

actual_sources_sha256=$(
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        source_path="$PROJECT_ROOT/$relative_path"
        source_sha256=$(/usr/bin/shasum -a 256 "$source_path" | awk '{print $1}')
        printf '%s  %s\n' "$source_sha256" "$relative_path"
    done <"$SOURCE_LIST" | /usr/bin/shasum -a 256 | awk '{print $1}'
)
[ "$actual_sources_sha256" = "$OPERATOR_PRODUCTION_SOURCES_SHA256" ] || {
    printf 'error: production Operator source checksum mismatch\n' >&2
    exit 2
}

if patch -d "$SOURCE_ROOT" -p1 --forward --dry-run <"$COMPATIBILITY_PATCH" >/dev/null 2>&1; then
    patch -d "$SOURCE_ROOT" -p1 --forward <"$COMPATIBILITY_PATCH"
elif patch -d "$SOURCE_ROOT" -p1 --reverse --dry-run <"$COMPATIBILITY_PATCH" >/dev/null 2>&1; then
    printf 'Compatibility patch already applied.\n'
else
    printf 'error: compatibility patch does not apply cleanly\n' >&2
    exit 2
fi

if patch -d "$SOURCE_ROOT" -p1 --forward --dry-run <"$PACKAGING_PATCH" >/dev/null 2>&1; then
    patch -d "$SOURCE_ROOT" -p1 --forward <"$PACKAGING_PATCH"
elif patch -d "$SOURCE_ROOT" -p1 --reverse --dry-run <"$PACKAGING_PATCH" >/dev/null 2>&1; then
    printf 'Operator packaging patch already applied.\n'
else
    printf 'error: Operator packaging patch does not apply cleanly\n' >&2
    exit 2
fi

if patch -d "$SOURCE_ROOT" -p1 --forward --dry-run <"$CALENDAR_EVENTKIT_PATCH" >/dev/null 2>&1; then
    patch -d "$SOURCE_ROOT" -p1 --forward <"$CALENDAR_EVENTKIT_PATCH"
elif patch -d "$SOURCE_ROOT" -p1 --reverse --dry-run <"$CALENDAR_EVENTKIT_PATCH" >/dev/null 2>&1; then
    printf 'Calendar EventKit patch already applied.\n'
else
    printf 'error: Calendar EventKit patch does not apply cleanly\n' >&2
    exit 2
fi

cp "$OPERATOR_INFO_PLIST" "$SOURCE_ROOT/Platform/iOS/Operator-Info.plist"
OPERATOR_APP_ICON_DESTINATION="$SOURCE_ROOT/Platform/Assets.xcassets/AppIcon.appiconset"
rm -rf "$OPERATOR_APP_ICON_DESTINATION"
mkdir -p "$OPERATOR_APP_ICON_DESTINATION"
cp -R "$APP_ICON_CATALOG/." "$OPERATOR_APP_ICON_DESTINATION/"

GENERATED_APP=$(mktemp "${TMPDIR:-/tmp}/operator-utm-app.XXXXXX")
trap 'rm -f "$GENERATED_APP"' EXIT HUP INT TERM
{
    printf '%s\n' '// Generated by ios/Runtime/utm/scripts/apply-overlay.sh. Do not edit in the UTM checkout.'
    printf '%s\n' 'import AppIntents'
    printf '%s\n' 'import AVFAudio'
    printf '%s\n' 'import Combine'
    printf '%s\n' 'import CoreLocation'
    printf '%s\n' 'import CryptoKit'
    printf '%s\n' 'import EventKit'
    printf '%s\n' 'import Foundation'
    printf '%s\n' 'import MessageUI'
    printf '%s\n' 'import OSLog'
    printf '%s\n' 'import Security'
    printf '%s\n' 'import Speech'
    printf '%s\n' 'import SwiftUI'
    printf '%s\n\n' 'import UIKit'

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        printf '// BEGIN %s\n' "$relative_path"
        case "$relative_path" in
            ios/OperatorApp/Sources/app/OperatorApp.swift)
                printf '%s\n' '// The standalone app declaration is replaced by the UTM-backed UTMApp below.'
                ;;
            ios/OperatorApp/Sources/chat/ChatScreen.swift)
                awk '
                    /^import / { next }
                    /^[[:space:]]*@main[[:space:]]*$/ { next }
                    /^[[:space:]]*await self\.setup\.check\(\)[[:space:]]*$/ { next }
                    { print }
                ' "$PROJECT_ROOT/$relative_path"
                ;;
            *)
                awk '
                    /^import / { next }
                    /^[[:space:]]*@main[[:space:]]*$/ { next }
                    { print }
                ' "$PROJECT_ROOT/$relative_path"
                ;;
        esac
        printf '// END %s\n\n' "$relative_path"
    done <"$SOURCE_LIST"

    printf '%s\n' '// BEGIN ios/Runtime/utm/overlay/UTMApp.swift'
    awk '/^import / { next } { print }' "$APP_OVERLAY"
    printf '%s\n' '// END ios/Runtime/utm/overlay/UTMApp.swift'
} >"$GENERATED_APP"

if grep -F 'OperatorRuntimeReadiness' "$GENERATED_APP" >/dev/null; then
    printf 'error: generated chat still uses the obsolete status-only runtime readiness shim\n' >&2
    exit 2
fi
setup_check_count=$(grep -F -c 'await self.setup.check()' "$GENERATED_APP")
[ "$setup_check_count" -eq 1 ] || {
    printf 'error: expected exactly one post-start model setup check, found %s\n' "$setup_check_count" >&2
    exit 2
}

mv "$GENERATED_APP" "$SOURCE_ROOT/Platform/iOS/UTMApp.swift"
trap - EXIT HUP INT TERM
printf 'Applied Operator UTM overlay to %s\n' "$SOURCE_ROOT"
