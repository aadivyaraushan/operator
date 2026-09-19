#!/bin/sh
# Contract and packaged-runtime discovery checks for the bundled WhatsApp CLI skill.
set -eu

runtime_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guest_dir="$runtime_dir/guest"
skill="$guest_dir/skills/wacli/SKILL.md"
provisioner="$guest_dir/first-boot/provision-guest.sh"
image_builder="$guest_dir/image-build/build-production-guest.sh"
runtime_package=${OPERATOR_TEST_OPENCLAW_PACKAGE:-/private/tmp/operator-openclaw-runtime-r3/usr/local/lib/node_modules/openclaw}
host_node=${OPERATOR_TEST_NODE_BIN:-node}
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_text() {
  grep -Fq -- "$2" "$1" || fail "${1#$runtime_dir/} lacks: $2"
}

test -f "$skill" || fail 'bundled WhatsApp skill is missing'
test -f "$provisioner" || fail 'guest provisioner is missing'
test -f "$image_builder" || fail 'guest image builder is missing'

if test -f "$skill"; then
  require_text "$skill" 'name: wacli'
  require_text "$skill" '"requires": { "bins": ["wacli"] }'
  require_text "$skill" 'Require explicit account-linking consent before running `wacli auth`.'
  require_text "$skill" 'Require an explicit recipient and exact message text.'
  require_text "$skill" 'Ask for a final confirmation that repeats both recipient and message immediately before `wacli send text`.'
  require_text "$skill" 'Skill instructions guide the agent; they are not an enforced security boundary.'
  require_text "$skill" 'does not automatically route WhatsApp conversations'
  require_text "$skill" '`wacli doctor`'
  require_text "$skill" '`wacli auth`'
  require_text "$skill" '`wacli chats list --limit 20 --query "name or number"`'
  require_text "$skill" '`wacli send text --to "+14155551212" --message "Hello! Are you free at 3pm?"`'
  if grep -Eq '("id": "brew"|"id": "go"|brew install|go install|Beeper)' "$skill"; then
    fail 'WhatsApp skill advertises an unsupported installer or Beeper'
  fi
fi

if test -f "$provisioner"; then
  require_text "$provisioner" 'install -d -o openclaw -g openclaw -m 0700 /var/lib/openclaw/.openclaw/workspace/skills/wacli'
  require_text "$provisioner" 'install -o openclaw -g openclaw -m 0600 "$skill_source/SKILL.md"'
fi

if test -f "$image_builder"; then
  require_text "$image_builder" '"$guest_dir/skills"'
fi

test -f "$runtime_package/openclaw.mjs" || fail "packaged OpenClaw entry is missing: $runtime_package/openclaw.mjs"
command -v "$host_node" >/dev/null || fail "host Node runtime is unavailable: $host_node"

if test -f "$skill"; then
  test_home=$(mktemp -d)
  trap 'rm -rf "$test_home"' EXIT HUP INT TERM
  staged_skill="$test_home/.openclaw/workspace/skills/wacli"
  mkdir -p "$staged_skill"
  cp "$skill" "$staged_skill/SKILL.md"
  config_path="$test_home/openclaw.json"
  printf '%s\n' '{"agents":{"defaults":{"workspace":"'"$test_home"'/.openclaw/workspace"}}}' \
    >"$config_path"
  discovery=$(OPENCLAW_STATE_DIR="$test_home/state" OPENCLAW_CONFIG_PATH="$config_path" \
    "$host_node" "$runtime_package/openclaw.mjs" skills list --json 2>&1) || {
    printf '%s\n' "$discovery" >&2
    fail 'actual packaged OpenClaw CLI did not list skills from temporary guest workspace'
  }
  if ! printf '%s' "$discovery" | node -e '
let raw=""; process.stdin.on("data", (part) => raw += part).on("end", () => {
  const skills = JSON.parse(raw).skills;
  const match = skills.find((entry) => entry.name === "wacli");
  if (!match || match.source !== "openclaw-workspace") process.exit(1);
});
'; then
    fail 'actual packaged OpenClaw CLI did not discover wacli as an openclaw-workspace skill'
  fi
fi

if test "$failures" -gt 0; then
  exit 1
fi

printf '%s\n' 'PASS: WhatsApp skill contract and packaged-runtime discovery'
