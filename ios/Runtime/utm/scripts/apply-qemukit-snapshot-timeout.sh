#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UTM_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$UTM_DIR/manifest.env"

[ "$#" -eq 1 ] || {
    printf 'Usage: %s /path/to/cloned-source-packages\n' "$(basename "$0")" >&2
    exit 2
}

QEMUKIT_ROOT=$1/checkouts/QEMUKit
PATCH_FILE=$UTM_DIR/overlay/qemukit-snapshot-timeout.patch
[ -d "$QEMUKIT_ROOT/.git" ] || {
    printf 'error: QEMUKit checkout is missing: %s\n' "$QEMUKIT_ROOT" >&2
    exit 2
}
actual_commit=$(git -C "$QEMUKIT_ROOT" rev-parse HEAD)
[ "$actual_commit" = "$QEMUKIT_COMMIT" ] || {
    printf 'error: expected QEMUKit commit %s, found %s\n' "$QEMUKIT_COMMIT" "$actual_commit" >&2
    exit 2
}
actual_sha256=$(/usr/bin/shasum -a 256 "$PATCH_FILE" | awk '{print $1}')
[ "$actual_sha256" = "$QEMUKIT_SNAPSHOT_TIMEOUT_PATCH_SHA256" ] || {
    printf 'error: QEMUKit snapshot timeout patch checksum mismatch\n' >&2
    exit 2
}

if git -C "$QEMUKIT_ROOT" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
    git -C "$QEMUKIT_ROOT" apply "$PATCH_FILE"
elif git -C "$QEMUKIT_ROOT" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    printf 'QEMUKit snapshot timeout patch already applied.\n'
else
    printf 'error: QEMUKit snapshot timeout patch does not apply cleanly\n' >&2
    exit 2
fi
