#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UTM_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
# shellcheck disable=SC1091
. "$UTM_DIR/manifest.env"

[ "$#" -eq 1 ] || {
    printf 'Usage: %s /path/to/pinned-QEMUKit-checkout\n' "$(basename "$0")" >&2
    exit 2
}

SOURCE_ROOT=$1
[ -d "$SOURCE_ROOT/.git" ] || {
    printf 'error: QEMUKit checkout is missing: %s\n' "$SOURCE_ROOT" >&2
    exit 2
}
actual_commit=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
[ "$actual_commit" = "$QEMUKIT_COMMIT" ] || {
    printf 'error: expected QEMUKit commit %s, found %s\n' "$QEMUKIT_COMMIT" "$actual_commit" >&2
    exit 2
}

TEMP_ROOT=$(mktemp -d /private/tmp/qemukit-snapshot-timeout-test.XXXXXX)
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
TEST_ROOT="$TEMP_ROOT/QEMUKit"
cp -R "$SOURCE_ROOT" "$TEST_ROOT"
git -C "$TEST_ROOT" apply "$UTM_DIR/overlay/qemukit-snapshot-timeout.patch"
git -C "$TEST_ROOT" apply "$SCRIPT_DIR/Package.test.patch"
cp "$SCRIPT_DIR/SnapshotTimeoutTests.swift" "$TEST_ROOT/Tests/QEMUKitTests/SnapshotTimeoutTests.swift"
cd "$TEST_ROOT"

GLIB_LIBRARY_PATH=$(pkg-config --libs-only-L glib-2.0 | sed 's/[[:space:]]*-L/:/g; s/^-L//')
[ -n "$GLIB_LIBRARY_PATH" ] || {
    printf 'error: pkg-config did not report a GLib library path\n' >&2
    exit 2
}
LIBRARY_PATH="$GLIB_LIBRARY_PATH" swift test \
    --filter QEMUKitTests.SnapshotTimeoutTests/testSnapshotDeadlineAllowsDelayedSuccess
LIBRARY_PATH="$GLIB_LIBRARY_PATH" swift test \
    --filter QEMUKitTests.SnapshotTimeoutTests/testRestoreDeadlineAllowsDelayedSuccess
LIBRARY_PATH="$GLIB_LIBRARY_PATH" swift test \
    --filter QEMUKitTests.SnapshotTimeoutTests/testOrdinaryCommandStillTimesOutAfterTenSeconds
