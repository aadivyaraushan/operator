#!/bin/sh
# Run as root inside a newly booted Alpine guest. It accepts only checked inputs.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/../definition/manifest.env"

usage() {
  printf '%s\n' "usage: $0 $OPENCLAW_RUNTIME_ARCHIVE RUNTIME_APK_DIRECTORY [WACLI_DIRECTORY]" >&2
  exit 64
}

test "$(id -u)" -eq 0 || {
  printf 'provisioning must run as root inside the fresh guest\n' >&2
  exit 77
}
test "$#" -ge 2 && test "$#" -le 3 || usage
runtime_archive=$1
runtime_apk_directory=$2
wacli_directory=${3:-}
runtime_apk_manifest=$script_dir/../definition/runtime-apks.sha256
case "$OPENCLAW_RUNTIME_SHA512" in
  *[!0123456789abcdefABCDEF]*)
    printf 'pinned runtime digest has the wrong shape\n' >&2
    exit 65
    ;;
esac
test "${#OPENCLAW_RUNTIME_SHA512}" -eq 128 || {
  printf 'pinned runtime digest has the wrong shape\n' >&2
  exit 65
}
test -f "$runtime_archive" || {
  printf 'checked OpenClaw runtime payload is missing: %s\n' "$runtime_archive" >&2
  exit 66
}
test -d "$runtime_apk_directory" && test -f "$runtime_apk_manifest" || {
  printf 'checked offline runtime packages are missing\n' >&2
  exit 66
}
actual_size=$(stat -c %s "$runtime_archive")
test "$actual_size" = "$OPENCLAW_RUNTIME_SIZE_BYTES" || {
  printf 'runtime payload size mismatch: expected %s, received %s\n' \
    "$OPENCLAW_RUNTIME_SIZE_BYTES" "$actual_size" >&2
  exit 67
}

printf '%s  %s\n' "$OPENCLAW_RUNTIME_SHA512" "$runtime_archive" | sha512sum -c -

# Install only the signed Alpine runtime libraries named by the checked
# manifest. Refuse extra APKs and never resolve dependencies over the network.
set --
expected_apk_count=0
while read -r apk_digest apk_name; do
  case "$apk_digest" in
    *[!0123456789abcdefABCDEF]*)
      printf 'offline package digest has the wrong shape\n' >&2
      exit 65
      ;;
  esac
  test "${#apk_digest}" -eq 64 || {
    printf 'offline package digest has the wrong shape\n' >&2
    exit 65
  }
  case "$apk_name" in
    *.apk) ;;
    *)
      printf 'offline package manifest has an invalid filename\n' >&2
      exit 65
      ;;
  esac
  case "$apk_name" in
    */*|*'..'*)
      printf 'offline package manifest filename is unsafe\n' >&2
      exit 65
      ;;
  esac
  test -f "$runtime_apk_directory/$apk_name" || {
    printf 'offline package is missing: %s\n' "$apk_name" >&2
    exit 66
  }
  set -- "$@" "$runtime_apk_directory/$apk_name"
  expected_apk_count=$((expected_apk_count + 1))
done <"$runtime_apk_manifest"

actual_apk_count=0
for candidate in "$runtime_apk_directory"/*.apk; do
  test -f "$candidate" || continue
  actual_apk_count=$((actual_apk_count + 1))
done
test "$actual_apk_count" -eq "$expected_apk_count" || {
  printf 'offline package directory contains an unexpected APK\n' >&2
  exit 67
}
(cd "$runtime_apk_directory" && sha256sum -c "$runtime_apk_manifest")
apk add --no-network "$@"
test -x /sbin/openrc-run && command -v rc-update >/dev/null

# The cloud image includes SSH only for server provisioning. Operator has no
# remote shell, so remove that server and every authorization/host-key file
# before the image becomes an app resource.
rc-update del sshd default >/dev/null 2>&1 || true
for ssh_package in openssh-server-pam openssh-server openssh; do
  if apk info -e "$ssh_package" >/dev/null 2>&1; then
    apk del --no-network "$ssh_package"
  fi
done
if apk info -e openssh-server >/dev/null 2>&1 || \
  apk info -e openssh-server-pam >/dev/null 2>&1; then
  printf 'SSH server packages remain after cleanup\n' >&2
  exit 78
fi
rm -f /root/.ssh/authorized_keys /home/alpine/.ssh/authorized_keys
rmdir /root/.ssh /home/alpine/.ssh 2>/dev/null || true
rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub \
  /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub \
  /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub
# The clean image uses cloud-init only for this offline build. Disable future
# cloud-init runs so an attached seed cannot recreate authorization files.
: > /etc/cloud/cloud-init.disabled

if ! getent group openclaw >/dev/null 2>&1; then
  addgroup -S openclaw
fi
if ! id -u openclaw >/dev/null 2>&1; then
  adduser -D -S -H -h /var/lib/openclaw -s /sbin/nologin -G openclaw openclaw
fi

install -d -o openclaw -g openclaw -m 0700 /var/lib/openclaw /run/openclaw

# The exact archive was built from the proven guest and contains only Node,
# OpenClaw, its launcher, and the matching SQLite runtime. No network package
# resolution happens here.
tar -xzf "$runtime_archive" -C /
test -f "/$OPENCLAW_REQUIRED_GATEWAY_MODULE" || {
  printf 'checked runtime is missing a Gateway startup module: %s\n' \
    "$OPENCLAW_REQUIRED_GATEWAY_MODULE" >&2
  exit 68
}
for workspace_template in \
  AGENTS.dev.md \
  AGENTS.md \
  BOOT.md \
  BOOTSTRAP.md \
  CLAUDE.md \
  HEARTBEAT.md \
  IDENTITY.dev.md \
  IDENTITY.md \
  SOUL.dev.md \
  SOUL.md \
  TOOLS.md \
  USER.dev.md \
  USER.md; do
  test -f "/usr/local/lib/node_modules/openclaw/docs/reference/templates/$workspace_template" || {
    printf 'checked runtime is missing workspace template: %s\n' "$workspace_template" >&2
    exit 68
  }
done
test -e /usr/local/bin/npm && test -e /usr/local/bin/npx && test -d /usr/local/lib/node_modules/npm || {
  printf 'checked runtime is missing the pinned npm CLI\n' >&2
  exit 68
}
chown root:root /usr/bin/node /usr/lib/libsqlite3.so.3.53.4
chown -h root:root /usr/lib/libsqlite3.so.0 /usr/local/bin/openclaw /usr/local/bin/npm /usr/local/bin/npx
chown -R root:root /usr/local/lib/node_modules/openclaw
chown -R root:root /usr/local/lib/node_modules/npm
/usr/bin/node --version | grep -Fxq "v${NODE_VERSION}"
/usr/local/bin/openclaw --version | grep -Fq "$OPENCLAW_VERSION"
test -x /usr/local/bin/npm && test -x /usr/local/bin/npx || {
  printf 'checked runtime npm CLI is not executable\n' >&2
  exit 68
}
/usr/local/bin/npm --version | grep -Fx '10.9.8' >/dev/null || {
  printf 'checked runtime npm version is not 10.9.8\n' >&2
  exit 68
}
config_dir=/var/lib/openclaw/.openclaw
managed_project_source=
for candidate in /usr/local/share/openclaw-plugins/openclaw-codex-*; do
  test -d "$candidate" || continue
  test -z "$managed_project_source" || {
    printf 'checked runtime contains multiple managed Codex projects\n' >&2
    exit 68
  }
  managed_project_source=$candidate
done
test -n "$managed_project_source" || {
  printf 'checked runtime is missing the managed Codex project\n' >&2
  exit 68
}
managed_project_name=$(basename "$managed_project_source")
managed_project_destination=$config_dir/npm/projects/$managed_project_name
install -d -o openclaw -g openclaw -m 0700 "$config_dir" "$config_dir/npm" "$config_dir/npm/projects"
test ! -e "$managed_project_destination" || {
  printf 'refusing to overwrite an existing managed Codex project: %s\n' "$managed_project_destination" >&2
  exit 68
}
cp -R "$managed_project_source" "$managed_project_destination"
chown -R openclaw:openclaw "$managed_project_destination"
workspace_dir=$config_dir/workspace
skills_dir=$workspace_dir/skills
install -d -o openclaw -g openclaw -m 0700 "$config_dir" "$workspace_dir" "$skills_dir"
install -d -o openclaw -g openclaw -m 0700 "$skills_dir/iphone-messages"
install -o openclaw -g openclaw -m 0600 "$script_dir/../skills/iphone-messages/SKILL.md" "$skills_dir/iphone-messages/SKILL.md"
skill_source=$script_dir/../skills/wacli
test -f "$skill_source/SKILL.md" || {
  printf 'bundled WhatsApp skill is missing\n' >&2
  exit 66
}
install -d -o openclaw -g openclaw -m 0700 "$skills_dir/wacli"
install -o openclaw -g openclaw -m 0600 "$skill_source/SKILL.md" \
  /var/lib/openclaw/.openclaw/workspace/skills/wacli/SKILL.md
if test -n "$wacli_directory"; then
  test -d "$wacli_directory" && test -f "$wacli_directory/wacli.sha256" && \
    test -f "$wacli_directory/wacli" || {
    printf 'checked wacli payload is missing\n' >&2
    exit 66
  }
  (cd "$wacli_directory" && sha256sum -c wacli.sha256)
  install -m 0755 "$wacli_directory/wacli" /usr/local/bin/wacli
  test -x /usr/local/bin/wacli || {
    printf 'installed wacli is not executable\n' >&2
    exit 68
  }
fi
wal_dir=$(mktemp -d)
trap 'rm -rf "$wal_dir"' EXIT HUP INT TERM
/usr/bin/node "$script_dir/verify-runtime.mjs" "$wal_dir/probe.sqlite" "$SQLITE_VERSION"

# Operator supplies native chat; do not build or serve the browser dashboard.
# New shell commands require approval; elevated execution must not bypass it.
whatsapp_plugin=/usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link
test -f "$whatsapp_plugin/openclaw.plugin.json" && test -f "$whatsapp_plugin/index.js" || {
  printf '[whatsapp-link] bundled iPhone plugin is missing\n' >&2
  exit 66
}
chown -R root:root "$whatsapp_plugin"
printf '%s\n' '{"gateway":{"mode":"local","bind":"lan","port":18789,"auth":{"mode":"token"},"controlUi":{"enabled":false},"nodes":{"commands":{"allow":["sms.compose","maps.search","maps.directions","apps.open"]}}},"plugins":{"load":{"paths":["/usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link"]},"entries":{"operator-iphone-whatsapp-link":{"enabled":true}}},"tools":{"exec":{"host":"gateway","mode":"ask"},"elevated":{"enabled":false}},"skills":{"workshop":{"autonomous":{"mode":"propose"}}}}' \
  >"$config_dir/openclaw.json"
chown openclaw:openclaw "$config_dir/openclaw.json"
chmod 0600 "$config_dir/openclaw.json"

runtime_source=$script_dir/../runtime-start
qga_normalize_allow_rpcs() {
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ',' | sed 's/,$//'
}
install -d -m 0755 /etc/qemu
cat > /etc/qemu/qemu-ga.conf <<'EOF'
[general]
daemon = false
method = virtio-serial
path = /dev/virtio-ports/org.qemu.guest_agent.0
pidfile = /run/qemu-ga.pid
statedir = /run
retry-path = true
allow-rpcs = guest-sync-delimited,guest-set-time
EOF
qga_dump=$(/usr/bin/qemu-ga --config /etc/qemu/qemu-ga.conf --dump-conf)
qga_effective_daemon=$(printf '%s\n' "$qga_dump" | sed -n 's/^[[:space:]]*daemon[[:space:]]*=[[:space:]]*//p')
qga_effective_allow_rpcs=$(printf '%s\n' "$qga_dump" | sed -n 's/^[[:space:]]*allow-rpcs[[:space:]]*=[[:space:]]*//p')
qga_normalized_allow_rpcs=$(qga_normalize_allow_rpcs "$qga_effective_allow_rpcs")
test "$qga_effective_daemon" = false || {
  printf 'QEMU guest agent is not foregrounded for OpenRC\n' >&2
  exit 69
}
test "$qga_normalized_allow_rpcs" = 'guest-set-time,guest-sync-delimited' || {
  printf 'QEMU guest agent RPC allow-list is not restricted\n' >&2
  exit 70
}
install -m 0755 "$runtime_source/time-sync/qemu-guest-agent.initd" \
  /etc/init.d/qemu-guest-agent
rc-update add qemu-guest-agent default
install -d -m 0755 /usr/local/libexec/openclaw
install -d -m 0755 /usr/local/libexec/openclaw/device-pairing
install -m 0755 "$runtime_source/inject-runtime-token.sh" \
  /usr/local/libexec/openclaw/inject-runtime-token.sh
install -m 0755 "$runtime_source/read-fw-cfg-token.sh" \
  /usr/local/libexec/openclaw/read-fw-cfg-token.sh
install -m 0755 "$runtime_source/device-pairing/approve-app-device.sh" \
  /usr/local/libexec/openclaw/device-pairing/approve-app-device.sh
install -m 0755 "$runtime_source/device-pairing/approve-app-device.mjs" \
  /usr/local/libexec/openclaw/device-pairing/approve-app-device.mjs
install -m 0755 "$runtime_source/openclaw-gateway.initd" \
  /etc/init.d/openclaw-gateway
rc-update add openclaw-gateway default

# No account, provider credential, gateway token, SSH key, or login password is
# created here. The gateway only receives a token through inject-runtime-token.
