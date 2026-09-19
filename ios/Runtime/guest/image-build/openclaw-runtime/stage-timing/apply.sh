#!/bin/sh
# Keep the pinned runtime's numeric embedded-run stage summaries at info level.
set -eu

runtime_root=${1:-}
expected_version=2026.9.1
package="$runtime_root/usr/local/lib/node_modules/openclaw/package.json"
dist="$runtime_root/usr/local/lib/node_modules/openclaw/dist"
builtin="$dist/builtin-openclaw-zQV8Wwjr.js"
embedded="$dist/embedded-agent-DaSvA-Yk.js"

test -n "$runtime_root" || { printf '%s\n' "usage: $0 RUNTIME_ROOT" >&2; exit 64; }
test -f "$package" || { printf 'OpenClaw package is missing: %s\n' "$package" >&2; exit 66; }
grep -Fq '"version":"2026.9.1"' "$package" || grep -Fq '"version": "2026.9.1"' "$package" || {
  printf 'runtime is not OpenClaw %s: %s\n' "$expected_version" "$package" >&2
  exit 66
}
test -f "$builtin" || { printf 'embedded timing module is missing: %s\n' "$builtin" >&2; exit 66; }
test -f "$embedded" || { printf 'embedded agent module is missing: %s\n' "$embedded" >&2; exit 66; }

require_count() {
  expected=$1
  needle=$2
  file=$3
  count=$(grep -F -c "$needle" "$file" || true)
  test "$count" -eq "$expected" || {
    printf 'expected exactly %s occurrence(s) of pinned timing anchor in %s, found %s\n' "$expected" "$file" "$count" >&2
    exit 67
  }
}

old_gate='if (!shouldWarn && !options.log.isEnabled("trace")) return;'
old_info='else options.log.trace(message);'
new_info='else options.log.info(message);'
old_core_gate='if (!shouldWarn && !log$5.isEnabled("trace")) return;'
old_core_info='else log$5.trace(message);'
new_core_info='else log$5.info(message);'
old_auth='const authStages = log$3.isEnabled("trace") ? createEmbeddedRunStageTracker() : void 0;'
new_auth='const authStages = createEmbeddedRunStageTracker();'
old_mark='authStages?.mark('
new_mark='authStages.mark('
old_emit='if (authStages) log$3.trace(formatEmbeddedRunStageSummary(`[trace:embedded-run] auth stages: runId=${params.runId} sessionId=${params.sessionId} phase=auth`, authStages.snapshot()));'
new_emit='createEmbeddedRunStageSummaryEmitter({ label: "auth stages", log: log$3, runId: params.runId, sessionId: params.sessionId, tracker: authStages })("auth");'

if grep -Fq "$new_info" "$builtin" && grep -Fq "$new_core_info" "$builtin" && \
   ! grep -Fq "$old_gate" "$builtin" && ! grep -Fq "$old_core_gate" "$builtin" && \
   grep -Fq "$new_auth" "$embedded" && grep -Fq "$new_emit" "$embedded" && \
   ! grep -Fq "$old_auth" "$embedded" && ! grep -Fq "$old_emit" "$embedded" && \
   ! grep -Fq "$old_mark" "$embedded"; then
  exit 0
fi

require_count 1 "$old_gate" "$builtin"
require_count 1 "$old_info" "$builtin"
require_count 1 "$old_core_gate" "$builtin"
require_count 1 "$old_core_info" "$builtin"
require_count 1 "$old_auth" "$embedded"
require_count 3 "$old_mark" "$embedded"
require_count 1 "$old_emit" "$embedded"

builtin_tmp="$builtin.tmp.$$"
embedded_tmp="$embedded.tmp.$$"
trap 'rm -f "$builtin_tmp" "$embedded_tmp"' EXIT HUP INT TERM

awk -v gate="$old_gate" -v old="$old_info" -v new="$new_info" \
    -v core_gate="$old_core_gate" -v core_old="$old_core_info" -v core_new="$new_core_info" '
  index($0, gate) { next }
  index($0, core_gate) { next }
  index($0, old) {
    position = index($0, old)
    print substr($0, 1, position - 1) new substr($0, position + length(old))
    next
  }
  index($0, core_old) {
    position = index($0, core_old)
    print substr($0, 1, position - 1) core_new substr($0, position + length(core_old))
    next
  }
  { print }
' "$builtin" > "$builtin_tmp"

awk -v old_auth="$old_auth" -v new_auth="$new_auth" \
    -v old_mark="$old_mark" -v new_mark="$new_mark" \
    -v old_emit="$old_emit" -v new_emit="$new_emit" '
  index($0, old_auth) {
    position = index($0, old_auth)
    print substr($0, 1, position - 1) new_auth substr($0, position + length(old_auth))
    next
  }
  index($0, old_emit) {
    position = index($0, old_emit)
    print substr($0, 1, position - 1) new_emit substr($0, position + length(old_emit))
    next
  }
  index($0, old_mark) {
    position = index($0, old_mark)
    print substr($0, 1, position - 1) new_mark substr($0, position + length(old_mark))
    next
  }
  { print }
' "$embedded" > "$embedded_tmp"

chmod 0644 "$builtin_tmp" "$embedded_tmp"
mv "$builtin_tmp" "$builtin"
mv "$embedded_tmp" "$embedded"
trap - EXIT HUP INT TERM
