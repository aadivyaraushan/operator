#!/bin/sh
# Patch the pinned OpenClaw detection timeout to preserve manifest-only setup options.
set -eu

runtime_root=${1:-}
expected_version=2026.9.1
target="$runtime_root/usr/local/lib/node_modules/openclaw/dist/setup-inference-detection-BPPYzRNV.js"
package="$runtime_root/usr/local/lib/node_modules/openclaw/package.json"

test -n "$runtime_root" || { printf '%s\n' "usage: $0 RUNTIME_ROOT" >&2; exit 64; }
test -f "$package" || { printf 'OpenClaw package is missing: %s\n' "$package" >&2; exit 66; }
grep -Fq '"version":"2026.9.1"' "$package" || grep -Fq '"version": "2026.9.1"' "$package" || {
  printf 'runtime is not OpenClaw %s: %s\n' "$expected_version" "$package" >&2
  exit 66
}
test -f "$target" || { printf 'detection module is missing: %s\n' "$target" >&2; exit 66; }

anchor='if (detection.candidates.length > 0 || detection.unavailableCandidates.length > 0) {'
replacement='if (detection.candidates.length > 0 || detection.unavailableCandidates.length > 0 || detection.authOptions?.length > 0 || detection.manualProviders?.length > 0) {'
count=$(grep -F -c "$anchor" "$target" || true)
already=$(grep -F -c "$replacement" "$target" || true)
if test "$already" -eq 1 && test "$count" -eq 0; then
  exit 0
fi
test "$count" -eq 1 || {
  printf 'expected exactly one timeout fallback anchor, found %s\n' "$count" >&2
  exit 67
}

temporary="$target.tmp.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
awk -v anchor="$anchor" -v replacement="$replacement" '
  { position = index($0, anchor)
    if (position) {
      print substr($0, 1, position - 1) replacement substr($0, position + length(anchor))
    } else print
  }
' "$target" > "$temporary"
mv "$temporary" "$target"
trap - EXIT HUP INT TERM
