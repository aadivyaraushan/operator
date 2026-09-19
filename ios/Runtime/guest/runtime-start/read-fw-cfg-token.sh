#!/bin/sh
# Reads root-staged QEMU launch values from volatile storage without persisting them.
set -eu

launch_dir=${OPENCLAW_LAUNCH_DIRECTORY:-/run/openclaw/launch}
token_path=$launch_dir/gateway-token
device_id_path=$launch_dir/device-id
public_key_path=$launch_dir/device-public-key
injector=/usr/local/libexec/openclaw/inject-runtime-token.sh
pairing_helper=/usr/local/libexec/openclaw/device-pairing/approve-app-device.sh

cleanup_launch_files() {
  rm -f "$token_path" "$device_id_path" "$public_key_path"
  rmdir "$launch_dir" 2>/dev/null || true
}
trap cleanup_launch_files EXIT HUP INT TERM

read_launch_file() {
  path=$1
  label=$2
  test -r "$path" || {
    printf 'OpenClaw %s is unavailable from volatile launch storage\n' "$label" >&2
    exit 69
  }
  cat "$path"
}

# Do not print the resulting token or place it in a command argument.
token=$(read_launch_file "$token_path" 'launch token')
device_id=$(read_launch_file "$device_id_path" 'app device id')
public_key=$(read_launch_file "$public_key_path" 'app public key')
test -n "$token" || {
  printf 'OpenClaw launch token from QEMU fw_cfg is empty\n' >&2
  exit 71
}
case "$token" in
  *' '*|*'
'*|*'	'*)
    printf 'OpenClaw launch token from QEMU fw_cfg has invalid whitespace\n' >&2
    exit 72
    ;;
esac

test "${#device_id}" -eq 64 || {
  printf 'OpenClaw app device id has the wrong length\n' >&2
  exit 73
}
case "$device_id" in
  *[!0123456789abcdef]*)
    printf 'OpenClaw app device id has the wrong shape\n' >&2
    exit 73
    ;;
esac
test "${#public_key}" -eq 43 || {
  printf 'OpenClaw app public key has the wrong length\n' >&2
  exit 74
}
case "$public_key" in
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*)
    printf 'OpenClaw app public key has the wrong shape\n' >&2
    exit 74
    ;;
esac
test -x "$injector" && test -x "$pairing_helper" || {
  printf 'OpenClaw runtime launch helpers are not installed\n' >&2
  exit 70
}

cleanup_launch_files
trap - EXIT HUP INT TERM

# The helper approves only this app installation's exact signed identity. Its
# parent pid remains the Gateway pid after exec, so it exits if the Gateway does.
env "OPENCLAW_GATEWAY_TOKEN=$token" \
  "OPENCLAW_EXPECTED_DEVICE_ID=$device_id" \
  "OPENCLAW_EXPECTED_PUBLIC_KEY=$public_key" \
  "OPENCLAW_GATEWAY_PARENT_PID=$$" \
  "$pairing_helper" &

exec env "OPENCLAW_RUNTIME_TOKEN=$token" "$injector" "$@"
