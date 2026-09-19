#!/bin/sh
# Package the checked runtime with pinned templates, npm and the Codex project.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_root=${1:-/private/tmp/operator-openclaw-runtime-r2}
openclaw_source=${2:-/private/tmp/openclaw-2026.9.1-source}
npm_tarball=${3:-/private/tmp/npm-10.9.8.tgz}
output_archive=${4:-/private/tmp/operator-openclaw-runtime-2026.9.1-r5.tar.gz}
managed_project=${5:-}
expected_version=2026.9.1
expected_commit=ad6fe23
npm_sri='sha512-fYwb6ODSmHkqrJQQaCxY3M2lPf/mpgC7ik0HSzzIwG5CGtabRp4bNqikatvCoT42b5INQSqudVH0R7yVmC9hVg=='
openclaw_source_sri='sha512-0Ve0631CdgkJDwd4NNG1BawIdF5yCL2sO+Tts8amStw+H6vKURTj0K4rOa4+hFpJk1Dnw5LyKl5twzwX1VtA2w=='
openclaw_source_digest='0Ve0631CdgkJDwd4NNG1BawIdF5yCL2sO+Tts8amStw+H6vKURTj0K4rOa4+hFpJk1Dnw5LyKl5twzwX1VtA2w=='
runtime_package=$runtime_root/usr/local/lib/node_modules/openclaw/package.json
managed_project_verifier=$script_dir/../codex-plugin/verify-managed-project.mjs
source_package=
templates_source=
source_unpack_root=
staging_root=
pinned_claude_copy=

test -d "$runtime_root" || {
  printf 'runtime root is missing: %s\n' "$runtime_root" >&2
  exit 66
}
test -f "$npm_tarball" || {
  printf 'pinned npm-10.9.8.tgz is missing: %s\n' "$npm_tarball" >&2
  exit 66
}
test -n "$managed_project" && test -d "$managed_project" || {
  printf 'checked managed Codex project is missing: %s\n' "$managed_project" >&2
  exit 66
}
managed_project_name=$(basename -- "$managed_project")
case "$managed_project_name" in
  openclaw-codex-*) ;;
  *)
    printf 'managed Codex project has an unsafe name: %s\n' "$managed_project_name" >&2
    exit 65
    ;;
esac
test -f "$managed_project_verifier" || {
  printf 'managed Codex project verifier is missing: %s\n' "$managed_project_verifier" >&2
  exit 66
}
grep -Fqx "  \"version\": \"$expected_version\"," "$runtime_package" || {
  printf 'runtime package is not OpenClaw %s: %s\n' "$expected_version" "$runtime_package" >&2
  exit 66
}
if test -d "$openclaw_source"; then
  source_package=$openclaw_source/package.json
  templates_source=$openclaw_source/docs/reference/templates
  grep -Fqx "  \"version\": \"$expected_version\"," "$source_package" || {
    printf 'template source is not OpenClaw %s: %s\n' "$expected_version" "$source_package" >&2
    exit 66
  }
  test "$(git -C "$openclaw_source" rev-parse --short=7 HEAD)" = "$expected_commit" || {
    printf 'template source is not pinned commit %s\n' "$expected_commit" >&2
    exit 66
  }
elif test -f "$openclaw_source"; then
  actual_source_digest=$(openssl dgst -sha512 -binary "$openclaw_source" | openssl base64 -A)
  test "$actual_source_digest" = "$openclaw_source_digest" || {
    printf 'openclaw archive digest mismatch\n' >&2
    exit 67
  }
  tar -tzf "$openclaw_source" | awk '
    $0 !~ /^package\// || $0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /^\// { exit 1 }
    END { if (NR == 0) exit 1 }
  ' || {
    printf 'openclaw source archive contains an unsafe path\n' >&2
    exit 65
  }
  source_unpack_root=$(mktemp -d "${TMPDIR:-/tmp}/operator-openclaw-source.XXXXXX")
  tar -xzf "$openclaw_source" -C "$source_unpack_root"
  source_package=$source_unpack_root/package/package.json
  templates_source=$source_unpack_root/package/docs/reference/templates
  grep -Fqx "  \"version\": \"$expected_version\"," "$source_package" && \
    grep -Fq "  \"commit\": \"$expected_commit" "$source_unpack_root/package/dist/build-info.json" || {
    printf 'published OpenClaw source version or commit is not pinned\n' >&2
    exit 66
  }
  test "$openclaw_source_sri" = "sha512-$actual_source_digest" || {
    printf 'openclaw source digest pin is malformed\n' >&2
    exit 65
  }
else
  printf 'pinned workspace source is missing: %s\n' "$openclaw_source" >&2
  exit 66
fi
test -d "$templates_source" || {
  printf 'pinned workspace templates are missing: %s\n' "$templates_source" >&2
  exit 66
}
test ! -e "$output_archive" || {
  printf 'refusing to overwrite runtime archive: %s\n' "$output_archive" >&2
  exit 67
}

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/operator-openclaw-runtime-r3.XXXXXX")
trap 'test -z "$staging_root" || rm -rf "$staging_root"; test -z "$source_unpack_root" || rm -rf "$source_unpack_root"; test -z "$pinned_claude_copy" || rm -f "$pinned_claude_copy"' EXIT HUP INT TERM
cp -R "$runtime_root"/. "$staging_root"
"$script_dir/patch-detection-timeout-fallback.sh" "$staging_root"
"$script_dir/stage-timing/apply.sh" "$staging_root"
bootstrap_module="$staging_root/usr/local/lib/node_modules/openclaw/dist/builtin-openclaw-zQV8Wwjr.js"
node "$script_dir/bootstrap-timing/apply.mjs" "$bootstrap_module" "$bootstrap_module.bootstrap-timing"
chmod 0644 "$bootstrap_module.bootstrap-timing"
mv "$bootstrap_module.bootstrap-timing" "$bootstrap_module"
server_module="$staging_root/usr/local/lib/node_modules/openclaw/dist/server-start-BNcm1gUN.js"
node "$script_dir/compile-cache-checkpoint/apply.mjs" "$server_module" "$server_module.compile-cache-checkpoint"
chmod 0644 "$server_module.compile-cache-checkpoint"
mv "$server_module.compile-cache-checkpoint" "$server_module"
observer_module="$staging_root/usr/local/lib/node_modules/openclaw/dist/attempt.model-diagnostic-events-B4dGIs0S.js"
node "$script_dir/provider-timing/apply.mjs" "$observer_module" "$observer_module.provider-timing"
chmod 0644 "$observer_module.provider-timing"
mv "$observer_module.provider-timing" "$observer_module"
"$script_dir/stage-npm.sh" "$npm_tarball" "$npm_sri" "$staging_root"
pinned_templates=$staging_root/usr/local/lib/node_modules/openclaw/docs/reference/templates
pinned_claude_template=$pinned_templates/CLAUDE.md
pinned_agents_template=$pinned_templates/AGENTS.md
test -f "$pinned_claude_template" || {
  printf 'missing pinned CLAUDE.md in the runtime provenance\n' >&2
  exit 68
}
test -f "$pinned_agents_template" || {
  printf 'missing pinned AGENTS.md in the runtime provenance\n' >&2
  exit 68
}
cmp -s "$pinned_claude_template" "$pinned_agents_template" || {
  printf 'pinned CLAUDE.md is not the expected AGENTS.md compatibility alias\n' >&2
  exit 68
}
pinned_claude_checksum=$(sha256sum "$pinned_claude_template" | awk '{print $1}')
pinned_claude_copy=$(mktemp "${TMPDIR:-/tmp}/operator-pinned-claude.XXXXXX")
cp "$pinned_claude_template" "$pinned_claude_copy"
mkdir -p "$staging_root/usr/local/lib/node_modules/openclaw/docs/reference"
rm -rf "$pinned_templates"
cp -R "$templates_source" "$pinned_templates"
cp "$pinned_claude_copy" "$pinned_templates/CLAUDE.md"
test "$(sha256sum "$pinned_templates/CLAUDE.md" | awk '{print $1}')" = "$pinned_claude_checksum" || {
  printf 'pinned CLAUDE.md checksum changed while staging templates\n' >&2
  exit 68
}
node "$managed_project_verifier" \
  --project-root "$managed_project" \
  --openclaw-root "$staging_root/usr/local/lib/node_modules/openclaw" >/dev/null
managed_project_destination=$staging_root/usr/local/share/openclaw-plugins/$managed_project_name
test ! -e "$managed_project_destination" || {
  printf 'refusing to overwrite staged managed Codex project: %s\n' "$managed_project_destination" >&2
  exit 67
}
mkdir -p "$staging_root/usr/local/share/openclaw-plugins"
cp -R "$managed_project" "$managed_project_destination"
node "$managed_project_verifier" \
  --project-root "$managed_project_destination" \
  --openclaw-root "$staging_root/usr/local/lib/node_modules/openclaw" >/dev/null

sh "$script_dir/whatsapp-link/stage.sh" "$script_dir/../../whatsapp-link/plugin" "$staging_root"

(cd "$staging_root" && tar -czf "$output_archive" usr)
