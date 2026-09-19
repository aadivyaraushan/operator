#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UTM_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$UTM_DIR/manifest.env"

[ "$#" -eq 1 ] || {
    printf 'Usage: %s /path/to/UTM-source\n' "$(basename "$0")" >&2
    exit 2
}

SOURCE_ROOT=$1
PATCH_FILE=$UTM_DIR/overlay/utm-restore-result.patch
[ -d "$SOURCE_ROOT/.git" ] || {
    printf 'error: UTM checkout is missing: %s\n' "$SOURCE_ROOT" >&2
    exit 2
}
actual_commit=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
[ "$actual_commit" = "$UTM_COMMIT" ] || {
    printf 'error: expected UTM commit %s, found %s\n' "$UTM_COMMIT" "$actual_commit" >&2
    exit 2
}
actual_sha256=$(/usr/bin/shasum -a 256 "$PATCH_FILE" | awk '{print $1}')
[ "$actual_sha256" = "$UTM_RESTORE_RESULT_PATCH_SHA256" ] || {
    printf 'error: UTM restore-result patch checksum mismatch\n' >&2
    exit 2
}

if git -C "$SOURCE_ROOT" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
    git -C "$SOURCE_ROOT" apply "$PATCH_FILE"
elif git -C "$SOURCE_ROOT" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    printf 'UTM restore-result patch already applied.\n'
else
    printf 'error: UTM restore-result patch does not apply cleanly\n' >&2
    exit 2
fi
