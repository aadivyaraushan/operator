#!/bin/sh
# Shell-level contract checks for the clean UTM SE guest scaffolding.
set -eu

runtime_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guest_dir="$runtime_dir/guest"
failures=0

# Inspect the actual first-boot JSON without executing privileged provisioning.
node --input-type=module - "$guest_dir/first-boot/provision-guest.sh" <<'JS' || exit 1
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const source = readFileSync(process.argv[2], 'utf8');
const configs = source.split('\n').filter(line => line.startsWith("printf '%s\\n' '{\"gateway\":"));
assert.equal(configs.length, 1, 'exactly one initial Gateway configuration');
const config = JSON.parse(configs[0].split("'")[3]);
assert.deepEqual(config.gateway.nodes?.commands?.allow, ['sms.compose', 'maps.search', 'maps.directions', 'apps.open'], 'allow the declared native connector commands, not direct send');
assert.equal(config.tools.exec.mode, 'ask', 'keep shell approval');
assert.equal(config.tools.elevated.enabled, false, 'keep elevated execution disabled');
console.log('PASS: initial Gateway policy permits declared native connector commands and preserves approval gates');
JS

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  test -f "$1" || fail "missing ${1#$runtime_dir/}"
}

require_text() {
  file=$1
  text=$2
  grep -Fqx "$text" "$file" || fail "${file#$runtime_dir/} lacks: $text"
}

require_file "$guest_dir/definition/manifest.env"
require_file "$guest_dir/definition/runtime-apks.sha256"
require_file "$guest_dir/image-build/build-clean-image.sh"
require_file "$guest_dir/first-boot/provision-guest.sh"
require_file "$guest_dir/first-boot/verify-runtime.mjs"
require_file "$guest_dir/runtime-start/inject-runtime-token.sh"
require_file "$guest_dir/runtime-start/read-fw-cfg-token.sh"
require_file "$guest_dir/runtime-start/openclaw-gateway.initd"
require_file "$guest_dir/runtime-start/time-sync/qemu-guest-agent.initd"
require_file "$guest_dir/runtime-start/device-pairing/approve-app-device.sh"
require_file "$guest_dir/runtime-start/device-pairing/approve-app-device.mjs"
require_file "$guest_dir/README.md"
require_file "$guest_dir/skills/iphone-messages/SKILL.md"
require_text "$guest_dir/first-boot/provision-guest.sh" 'install -d -o openclaw -g openclaw -m 0700 "$skills_dir/iphone-messages"'
require_text "$guest_dir/first-boot/provision-guest.sh" 'install -o openclaw -g openclaw -m 0600 "$script_dir/../skills/iphone-messages/SKILL.md" "$skills_dir/iphone-messages/SKILL.md"'

if test -f "$guest_dir/definition/manifest.env"; then
  require_text "$guest_dir/definition/manifest.env" 'ALPINE_VERSION=3.22.5'
  require_text "$guest_dir/definition/manifest.env" 'GUEST_ARCH=x86_64'
  require_text "$guest_dir/definition/manifest.env" 'GUEST_DISK_SIZE=4G'
  require_text "$guest_dir/definition/manifest.env" 'ALPINE_IMAGE_SHA512=463f44e95fca714a84d37f9725337f99f54fe4b210488848489584910d8a33afcc8d67ff89737467e099781a09c0d798309fd661ef8e7173cd31a01b47d81705'
  require_text "$guest_dir/definition/manifest.env" 'NODE_VERSION=22.23.2'
  require_text "$guest_dir/definition/manifest.env" 'OPENCLAW_VERSION=2026.9.1'
  require_text "$guest_dir/definition/manifest.env" 'OPENCLAW_GIT_COMMIT=ad6fe23'
  require_text "$guest_dir/definition/manifest.env" 'OPENCLAW_RUNTIME_ARCHIVE=operator-openclaw-runtime-2026.9.1-r7-stage-timing.tar.gz'
  require_text "$guest_dir/definition/manifest.env" 'OPENCLAW_RUNTIME_SHA512=056e63f2ed0f363e934e4a7f484f8ef4ddc47791efea856e181e22415f88e884a02ed32975f6c68c6160d3ca141afe6f54b6821a5b8e5096561e6924fa34bb90'
  require_text "$guest_dir/definition/manifest.env" 'OPENCLAW_RUNTIME_SIZE_BYTES=246353659'
  require_text "$guest_dir/definition/manifest.env" 'OPENCLAW_REQUIRED_GATEWAY_MODULE=usr/local/lib/node_modules/openclaw/dist/push-apns-http2-CcgxgbKC.js'
  require_text "$guest_dir/definition/manifest.env" 'SQLITE_VERSION=3.53.4'
fi

if test -f "$guest_dir/definition/runtime-apks.sha256"; then
  apk_count=$(wc -l <"$guest_dir/definition/runtime-apks.sha256" | tr -d ' ')
  test "$apk_count" = 24 || fail 'runtime APK manifest must pin exactly 24 offline runtime packages including the guest agent'
  grep -Fq 'qemu-guest-agent-' "$guest_dir/definition/runtime-apks.sha256" || fail 'runtime APK manifest does not pin qemu-guest-agent'
fi

if test -f "$guest_dir/image-build/build-clean-image.sh"; then
  grep -Fq 'ALPINE_IMAGE_SHA512' "$guest_dir/image-build/build-clean-image.sh" || fail 'builder does not use the pinned full Alpine SHA-512'
  grep -Fq 'test "${#ALPINE_IMAGE_SHA512}" -eq 128' "$guest_dir/image-build/build-clean-image.sh" || fail 'builder does not enforce a 128-character Alpine digest'
  grep -Fq 'ALPINE_IMAGE_SHA512_PREFIX' "$guest_dir/image-build/build-clean-image.sh" || fail 'builder does not check the recorded Alpine digest prefix'
  grep -Fq 'sha512sum -c' "$guest_dir/image-build/build-clean-image.sh" || fail 'builder does not verify Alpine input with sha512sum'
  grep -Fq 'qemu-img convert' "$guest_dir/image-build/build-clean-image.sh" || fail 'builder does not create a fresh qcow2 output'
  grep -Fq 'qemu-img resize "$output_image" "$GUEST_DISK_SIZE"' "$guest_dir/image-build/build-clean-image.sh" || fail 'builder does not reserve enough guest storage for OpenClaw'
fi

if test -f "$guest_dir/first-boot/provision-guest.sh"; then
  grep -Fq 'OPENCLAW_RUNTIME_SHA512' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not verify the pinned runtime payload'
  grep -Fq 'OPENCLAW_RUNTIME_SIZE_BYTES' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not verify the runtime payload size'
  grep -Fq 'tar -xzf "$runtime_archive" -C /' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not install the checked runtime payload'
  grep -Fq 'test -f "/$OPENCLAW_REQUIRED_GATEWAY_MODULE"' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not reject a runtime missing the Gateway APNs module'
  grep -Fq 'checked runtime is missing the pinned npm CLI' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not require the pinned npm CLI'
  grep -Fq '/usr/local/share/openclaw-plugins/openclaw-codex-' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not require the staged managed Codex project'
  grep -Fq 'managed_project_destination=$config_dir/npm/projects/$managed_project_name' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not copy the managed Codex project into the OpenClaw npm projects root'
  grep -Fq 'test ! -e "$managed_project_destination"' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner can overwrite a later user-managed plugin project'
  grep -Fq 'chown -R openclaw:openclaw "$managed_project_destination"' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not make the recovered managed project readable by OpenClaw'
  grep -Fq '/usr/local/bin/npm --version | grep -Fx '\''10.9.8'\''' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not verify the pinned npm version'
  grep -Fq 'chown -R root:root /usr/local/lib/node_modules/npm' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not make the packaged npm tree root-owned'
  grep -Fq 'checked runtime is missing workspace template' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not reject a runtime missing workspace templates'
  for workspace_template in \
    AGENTS.dev.md AGENTS.md BOOT.md BOOTSTRAP.md CLAUDE.md HEARTBEAT.md \
    IDENTITY.dev.md IDENTITY.md SOUL.dev.md SOUL.md TOOLS.md USER.dev.md USER.md; do
    grep -Fq "$workspace_template" "$guest_dir/first-boot/provision-guest.sh" || \
      fail "provisioner does not require workspace template: $workspace_template"
  done
  grep -Fq 'runtime-apks.sha256' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not use the offline dependency manifest'
  grep -Fq 'sha256sum -c' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not checksum offline dependency packages'
  grep -Fq 'apk add --no-network' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner can still resolve runtime dependencies over the network'
  grep -Fq 'openssh-server-pam' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not account for Alpine cloud images with the PAM SSH server variant'
  grep -Fq 'apk del --no-network "$ssh_package"' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not remove each installed SSH package variant'
  grep -Fq 'rm -f /root/.ssh/authorized_keys /home/alpine/.ssh/authorized_keys' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner leaves cloud-image SSH authorization files behind'
  grep -Fq ': > /etc/cloud/cloud-init.disabled' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner allows cloud-init to recreate remote-access state on later boots'
  grep -Fq 'verify-runtime.mjs' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not run the Node and SQLite behavior proof'
  grep -Fq '/usr/bin/node --version' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not check bundled Node version'
  grep -Fq '/usr/local/bin/openclaw --version' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not check bundled OpenClaw version'
  grep -Fq 'adduser -D' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not create an unprivileged OpenClaw account'
  grep -Fq 'workspace_dir=$config_dir/workspace' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not name the gateway workspace directory'
  grep -Fq 'skills_dir=$workspace_dir/skills' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not name the gateway skills parent directory'
  grep -Fq 'install -d -o openclaw -g openclaw -m 0700 "$config_dir" "$workspace_dir" "$skills_dir"' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not create the workspace and skills roots for the gateway account'
  grep -Fq 'rc-update add openclaw-gateway default' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not enable the local gateway service'
  grep -Fq 'daemon = false' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not keep the guest agent foregrounded for OpenRC supervision'
  grep -Fq 'retry-path = true' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not make the guest agent retry a delayed virtio channel'
  grep -Fq 'allow-rpcs = guest-sync-delimited,guest-set-time' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not restrict guest-agent RPCs to synchronization and time correction'
  grep -Fq 'qemu-ga --config /etc/qemu/qemu-ga.conf --dump-conf' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not validate the guest-agent configuration with the packaged binary'
  grep -Fq 'qga_effective_allow_rpcs' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not parse the packaged guest-agent RPC configuration'
  grep -Fq 'qga_normalized_allow_rpcs' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not normalize the packaged guest-agent RPC set before comparison'
  grep -Fq 'qga_normalize_allow_rpcs()' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not keep guest-agent RPC normalization in a testable production function'
  grep -Fq 'LC_ALL=C sort' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not compare the guest-agent RPC set independently of package ordering'
  grep -Fq 'guest-sync-delimited,guest-set-time' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not reject an expanded guest-agent RPC allow-list'
  grep -Fq 'guest-set-time,guest-sync-delimited' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not accept the packaged agent’s reordered exact RPC set'
  grep -Fq '/dev/virtio-ports/org.qemu.guest_agent.0' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not configure the QEMU guest agent channel'
  grep -Fq 'rc-update add qemu-guest-agent default' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not enable the QEMU guest agent service'
  grep -Fq '"controlUi":{"enabled":false}' "$guest_dir/first-boot/provision-guest.sh" || fail 'native app guest still enables the unused browser dashboard'
  grep -Fq '"skills":{"workshop":{"autonomous":{"mode":"propose"}}}' "$guest_dir/first-boot/provision-guest.sh" || fail 'provisioner does not defer automatic skill collection reviews to preserve user-requested skill work'
  if grep -Eq '(npm install|NODE_ARCHIVE|node_archive)' "$guest_dir/first-boot/provision-guest.sh"; then
    fail 'provisioner retains the old split Node/npm install path'
  fi
  if grep -Eq '(apk add --no-cache|https?://)' "$guest_dir/first-boot/provision-guest.sh"; then
    fail 'provisioner retains a live network package path'
  fi
  qga_function_test=$(mktemp)
  sed -n '/^qga_normalize_allow_rpcs()/,/^}/p' "$guest_dir/first-boot/provision-guest.sh" >"$qga_function_test"
  . "$qga_function_test"
  command rm -f "$qga_function_test"
  qga_required_rpcs='guest-set-time,guest-sync-delimited'
  test "$(qga_normalize_allow_rpcs 'guest-sync-delimited,guest-set-time')" = "$qga_required_rpcs" || \
    fail 'guest agent validation does not accept the package’s reversed RPC order'
  test "$(qga_normalize_allow_rpcs 'guest-set-time,guest-sync-delimited')" = "$qga_required_rpcs" || \
    fail 'guest agent validation does not accept the canonical exact RPC order'
  test "$(qga_normalize_allow_rpcs 'guest-sync-delimited,guest-set-time,guest-info')" != "$qga_required_rpcs" || \
    fail 'guest agent validation accepts an expanded RPC set'
fi

if test -f "$guest_dir/runtime-start/time-sync/qemu-guest-agent.initd"; then
  if ! (
    . "$guest_dir/runtime-start/time-sync/qemu-guest-agent.initd"
    test "${command:-}" = /usr/bin/qemu-ga &&
      test "${command_args:-}" = '--config /etc/qemu/qemu-ga.conf' &&
      test "${command_background:-}" = yes &&
      test "${pidfile:-}" = /run/qemu-ga.pid &&
      test "${retry:-}" = 'TERM/10/KILL/5' &&
      test "${output_log:-}" = /var/log/qemu-guest-agent/agent.log &&
      test "${error_log:-}" = /var/log/qemu-guest-agent/agent.err
  ); then
    fail 'guest agent service must run the restricted foreground agent with private diagnostics'
  fi
  if ! (
    . "$guest_dir/runtime-start/time-sync/qemu-guest-agent.initd"
    prepared_directory=false
    prepared_files=false
    checkpath() {
      if test "$*" = '--directory --owner root:root --mode 0700 /var/log/qemu-guest-agent'; then
        prepared_directory=true
      elif test "$*" = '--file --owner root:root --mode 0600 /var/log/qemu-guest-agent/agent.log /var/log/qemu-guest-agent/agent.err'; then
        prepared_files=true
      fi
    }
    start_pre
    test "$prepared_directory" = true && test "$prepared_files" = true
  ); then
    fail 'guest agent service must prepare root-only diagnostic paths before launch'
  fi
fi

if test -f "$guest_dir/first-boot/verify-runtime.mjs"; then
  grep -Fq 'from "node:sqlite"' "$guest_dir/first-boot/verify-runtime.mjs" || fail 'runtime proof does not use OpenClaw’s actual Node SQLite API'
  grep -Fq 'PRAGMA journal_mode=WAL' "$guest_dir/first-boot/verify-runtime.mjs" || fail 'runtime proof does not verify WAL mode'
  grep -Fq 'sqlite_version()' "$guest_dir/first-boot/verify-runtime.mjs" || fail 'runtime proof does not verify SQLite version'
fi

if test -f "$guest_dir/runtime-start/inject-runtime-token.sh"; then
  grep -Fq 'OPENCLAW_RUNTIME_TOKEN' "$guest_dir/runtime-start/inject-runtime-token.sh" || fail 'runtime token injector has no token input'
  grep -Fq 'OPENCLAW_RUNTIME_DIRECTORY:-/run/openclaw' "$guest_dir/runtime-start/inject-runtime-token.sh" || fail 'runtime token injector does not default to volatile /run storage'
  grep -Fq 'exec ' "$guest_dir/runtime-start/inject-runtime-token.sh" || fail 'runtime token injector does not replace itself with the gateway'
  runtime_test_dir=$(mktemp -d)
  if ! OPENCLAW_RUNTIME_DIRECTORY="$runtime_test_dir" \
    OPENCLAW_RUNTIME_TOKEN=contract-secret \
    "$guest_dir/runtime-start/inject-runtime-token.sh" \
    sh -c 'test "$OPENCLAW_GATEWAY_TOKEN" = contract-secret'; then
    fail 'runtime token injector does not pass the token to its child process'
  fi
  rmdir "$runtime_test_dir" || fail 'runtime token injector left token material behind'
fi

if test -f "$guest_dir/runtime-start/read-fw-cfg-token.sh"; then
  grep -Fq 'launch_dir=${OPENCLAW_LAUNCH_DIRECTORY:-/run/openclaw/launch}' "$guest_dir/runtime-start/read-fw-cfg-token.sh" || fail 'guest launcher does not read root-staged launch credentials from volatile storage'
  grep -Fq 'token_path=$launch_dir/gateway-token' "$guest_dir/runtime-start/read-fw-cfg-token.sh" || fail 'guest launcher does not read the staged gateway token'
  grep -Fq 'device_id_path=$launch_dir/device-id' "$guest_dir/runtime-start/read-fw-cfg-token.sh" || fail 'guest launcher does not read the staged app device id'
  grep -Fq 'public_key_path=$launch_dir/device-public-key' "$guest_dir/runtime-start/read-fw-cfg-token.sh" || fail 'guest launcher does not read the staged app public key'
  grep -Fq 'rm -f "$token_path" "$device_id_path" "$public_key_path"' "$guest_dir/runtime-start/read-fw-cfg-token.sh" || fail 'guest launcher leaves staged launch credentials in volatile storage'
  grep -Fq 'inject-runtime-token.sh' "$guest_dir/runtime-start/read-fw-cfg-token.sh" || fail 'fw_cfg reader bypasses the volatile token launcher'
  grep -Fq 'approve-app-device.sh' "$guest_dir/runtime-start/read-fw-cfg-token.sh" || fail 'fw_cfg reader does not launch exact-device pairing'
fi

if test -f "$guest_dir/runtime-start/openclaw-gateway.initd"; then
  if ! (
    . "$guest_dir/runtime-start/openclaw-gateway.initd"
    test "${NODE_COMPILE_CACHE:-}" = /var/tmp/openclaw-compile-cache || exit 1
    # Exercise preparation without touching host /run, accounts or launch values.
    cache_prepared=false
    workspace_prepared=false
    skills_prepared=false
    checkpath() {
      if test "$*" = '--directory --owner openclaw:openclaw --mode 0700 /var/tmp/openclaw-compile-cache'; then
        cache_prepared=true
      elif test "$*" = '--directory --owner openclaw:openclaw --mode 0700 /var/lib/openclaw/.openclaw/workspace'; then
        workspace_prepared=true
      elif test "$*" = '--directory --owner openclaw:openclaw --mode 0700 /var/lib/openclaw/.openclaw/workspace/skills'; then
        skills_prepared=true
      fi
    }
    rm() { :; }
    stage_fw_cfg() { :; }
    start_pre
    test "$cache_prepared" = true && test "$workspace_prepared" = true && test "$skills_prepared" = true
  ); then
    fail 'gateway must prepare a private persistent compile cache before launch'
  fi
  if ! (
    NODE_OPTIONS=--trace-deprecation
    . "$guest_dir/runtime-start/openclaw-gateway.initd"
    test "$NODE_OPTIONS" = '--trace-deprecation --disable-warning=ExperimentalWarning' &&
    test "${OPENCLAW_NO_RESPAWN:-}" != 1
  ); then
    fail 'gateway must apply the upstream warning option before launch without losing other Node options or bypassing certificate setup'
  fi
  if ! (
    . "$guest_dir/runtime-start/openclaw-gateway.initd"
    test "${log_dir:-}" = /var/lib/openclaw/.openclaw/logs &&
    test "${output_log:-}" = /var/lib/openclaw/.openclaw/logs/stdout.log &&
    test "${error_log:-}" = /var/lib/openclaw/.openclaw/logs/stderr.log &&
    test "${output_previous_log:-}" = /var/lib/openclaw/.openclaw/logs/stdout.previous.log &&
    test "${error_previous_log:-}" = /var/lib/openclaw/.openclaw/logs/stderr.previous.log &&
    test "${umask:-}" = 0077 &&
    test "${OPENCLAW_GATEWAY_STARTUP_TRACE:-}" = 1
  ); then
    fail 'gateway startup output must be kept privately across cold boots'
  fi
  if ! (
    log_test_dir=$(mktemp -d)
    . "$guest_dir/runtime-start/openclaw-gateway.initd"
    log_dir=$log_test_dir
    output_log=$log_dir/stdout.log
    error_log=$log_dir/stderr.log
    output_previous_log=$log_dir/stdout.previous.log
    error_previous_log=$log_dir/stderr.previous.log
    mkdir -p "$log_dir"
    printf '%s\n' prior-stdout >"$output_log"
    printf '%s\n' prior-stderr >"$error_log"
    logs_prepared=false
    logs_rotated=0
    checkpath() {
      if test "$1" = --directory && test "$6" = "$log_dir"; then
        logs_prepared=true
      elif test "$1" = --file && test "$6" = "$output_log" && test "$7" = "$output_previous_log"; then
        : >"$6"
        test -f "$7" || : >"$7"
        chmod 0600 "$6" "$7"
      elif test "$1" = --file && test "$6" = "$error_log" && test "$7" = "$error_previous_log"; then
        : >"$6"
        test -f "$7" || : >"$7"
        chmod 0600 "$6" "$7"
      fi
    }
    mv() { logs_rotated=$((logs_rotated + 1)); command mv "$@"; }
    rm() { :; }
    stage_fw_cfg() { :; }
    start_pre
    test "$logs_prepared" = true && test "$logs_rotated" = 2 &&
      test "$(cat "$output_previous_log")" = prior-stdout &&
      test "$(cat "$error_previous_log")" = prior-stderr &&
      test "$(stat -f %Lp "$output_log")" = 600 &&
      test "$(stat -f %Lp "$error_log")" = 600
    test_result=$?
    command rm -rf "$log_test_dir"
    exit "$test_result"
  ); then
    fail 'gateway startup does not retain one private previous log per stream'
  fi
  if ! (
    . "$guest_dir/runtime-start/openclaw-gateway.initd"
    test "${stopgroup:-}" = yes
  ); then
    fail 'stopping the Gateway must also stop its isolated pairing process group'
  fi
  grep -Fq 'checkpath --file --owner openclaw:openclaw --mode 0600 "$current_log" "$previous_log"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'startup log files must be owner-only before the process starts'
  grep -Fq 'checkpath --directory --owner openclaw:openclaw --mode 0700 "$log_dir"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'startup log directory must be private to the gateway account'
  grep -Fq 'mv -f "$current_log" "$previous_log"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'gateway startup does not rotate current logs before launch'
  grep -Fq 'checkpath --directory --owner openclaw:openclaw --mode 0700 "$workspace_dir"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'gateway startup does not repair the app-owned workspace root'
  grep -Fq 'checkpath --directory --owner openclaw:openclaw --mode 0700 "$skills_dir"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'gateway startup does not repair the app-owned skills parent directory'
  grep -Fq 'command_user="openclaw:openclaw"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'gateway service is not unprivileged'
  grep -Fq 'read-fw-cfg-token.sh' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'gateway service does not use runtime token delivery'
  grep -Fq 'export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:/usr/libexec/rc/bin' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'gateway service hides the OpenRC helper commands needed to start it'
  grep -Fq 'launch_source_path=/sys/firmware/qemu_fw_cfg/by_name/opt/openclaw/$launch_value_name/raw' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'root service setup does not read the protected QEMU launch credentials'
  grep -Fq 'chown openclaw:openclaw "$launch_destination_path"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'root service setup does not hand staged credentials to the unprivileged gateway account'
  grep -Fq 'chmod 0400 "$launch_destination_path"' "$guest_dir/runtime-start/openclaw-gateway.initd" || fail 'staged launch credentials are not owner-read-only'
fi

if test -f "$guest_dir/runtime-start/device-pairing/approve-app-device.sh"; then
  grep -Fq 'exec node /usr/local/libexec/openclaw/device-pairing/approve-app-device.mjs' "$guest_dir/runtime-start/device-pairing/approve-app-device.sh" || fail 'pairing launcher does not exec the persistent SDK helper'
  if grep -Fq -- 'openclaw devices' "$guest_dir/runtime-start/device-pairing/approve-app-device.sh"; then
    fail 'pairing helper can approve an unrelated latest request'
  fi
fi
if test -f "$guest_dir/runtime-start/device-pairing/approve-app-device.mjs"; then
  grep -Fq 'file:///usr/local/lib/node_modules/openclaw/dist/plugin-sdk/device-bootstrap.js' "$guest_dir/runtime-start/device-pairing/approve-app-device.mjs" || fail 'pairing helper does not use the installed public SDK entry'
  grep -Fq 'value.deviceId === expectedDeviceID && value.publicKey === expectedPublicKey' "$guest_dir/runtime-start/device-pairing/approve-app-device.mjs" || fail 'pairing helper does not require exact injected identity'
  grep -Fq "['operator', 'node']" "$guest_dir/runtime-start/device-pairing/approve-app-device.mjs" || fail 'pairing helper does not require both approved roles'
fi

if test -d "$guest_dir"; then
  if grep -RInE '(BEGIN (OPENSSH )?PRIVATE KEY|ssh-rsa |ssh-ed25519 |password[[:space:]]*=[^$[:space:]]|OPENAI_API_KEY[[:space:]]*=[^$[:space:]]|OPENCLAW_GATEWAY_TOKEN[[:space:]]*=[^$[:space:]])' "$guest_dir"; then
    fail 'guest scaffold contains a baked secret, password, or SSH key'
  fi
fi

if test "$failures" -gt 0; then
  exit 1
fi

printf 'PASS: clean guest scaffold contract\n'
