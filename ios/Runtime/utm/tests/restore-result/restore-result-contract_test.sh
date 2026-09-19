#!/bin/sh
set -eu

[ "$#" -eq 1 ] || {
    printf 'Usage: %s /path/to/UTM-source\n' "$(basename "$0")" >&2
    exit 2
}

source_file=$1/Services/UTMQemuVirtualMachine.swift
[ -f "$source_file" ] || {
    printf 'FAIL: missing UTMQemuVirtualMachine.swift\n' >&2
    exit 1
}

startup_restore=$(awk '/let isSuspended = await registryEntry\.isSuspended/,/try Task\.checkCancellation\(\)/ { print }' "$source_file")
printf '%s\n' "$startup_restore" | grep -F -- 'try await _restoreSnapshot(name: kSuspendSnapshotName)' >/dev/null || {
    printf 'FAIL: startup restore bypasses the checked restore helper\n' >&2
    exit 1
}
if printf '%s\n' "$startup_restore" | grep -F -- 'monitor.qemuRestoreSnapshot' >/dev/null; then
    printf 'FAIL: startup restore directly ignores the monitor result\n' >&2
    exit 1
fi

checked_helper=$(awk '/private func _restoreSnapshot\(name: String\)/,/^    }$/ { print }' "$source_file")
printf '%s\n' "$checked_helper" | grep -F -- 'let result = try await monitor.qemuRestoreSnapshot(name)' >/dev/null || {
    printf 'FAIL: restore helper does not retain monitor output\n' >&2
    exit 1
}
printf '%s\n' "$checked_helper" | grep -F -- 'result.localizedCaseInsensitiveContains("Error")' >/dev/null || {
    printf 'FAIL: restore helper does not reject monitor errors\n' >&2
    exit 1
}

printf 'PASS: startup restore checks monitor result\n'
