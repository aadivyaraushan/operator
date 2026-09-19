#!/bin/sh
# Approves only the native app identity injected for this VM launch.
set -eu

: "${OPENCLAW_EXPECTED_DEVICE_ID:?missing expected app device id}"
: "${OPENCLAW_EXPECTED_PUBLIC_KEY:?missing expected app public key}"
: "${OPENCLAW_GATEWAY_PARENT_PID:?missing Gateway parent pid}"

runtime_dir=/run/openclaw
error_file=$runtime_dir/app-device-error.log
umask 077
install -d -m 0700 "$runtime_dir"
: >"$error_file"
chmod 0600 "$error_file"
trap 'printf "[pairing] stopping on HUP\n" >&2; exit 129' HUP
trap 'printf "[pairing] stopping on INT\n" >&2; exit 130' INT
trap 'printf "[pairing] stopping on TERM\n" >&2; exit 143' TERM

attempt=0
printf '[pairing] waiting for the local Gateway before starting the pairing helper\n' >&2
while test "$attempt" -lt 300 && kill -0 "$OPENCLAW_GATEWAY_PARENT_PID" 2>/dev/null; do
  # Loading a second OpenClaw process competes with cold Gateway startup under
  # CPU interpretation. This local probe starts no Node process and sends no token.
  if ! wget -q -Y off -T 2 -O /dev/null http://127.0.0.1:18789/healthz 2>/dev/null; then
    sleep 1
    continue
  fi
  exec node /usr/local/libexec/openclaw/device-pairing/approve-app-device.mjs 2>>"$error_file"
done

printf 'OpenClaw app-device pairing did not complete during the startup window\n' >&2
exit 75
