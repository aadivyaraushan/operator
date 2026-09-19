#!/bin/sh
# Starts one gateway with a caller-supplied token held only in volatile /run.
set -eu

: "${OPENCLAW_RUNTIME_TOKEN:?provide the runtime token only for this launch}"
runtime_dir=${OPENCLAW_RUNTIME_DIRECTORY:-/run/openclaw}
token_file=$runtime_dir/runtime.env
umask 077
install -d -m 0700 "$runtime_dir"
trap 'rm -f "$token_file"' EXIT HUP INT TERM
printf '%s' "$OPENCLAW_RUNTIME_TOKEN" >"$token_file"
token=$(cat "$token_file")
rm -f "$token_file"
unset OPENCLAW_RUNTIME_TOKEN

# Keep the token out of persistent guest files and command arguments. The value
# lasts only in the Gateway process environment.
exec env "OPENCLAW_GATEWAY_TOKEN=$token" "$@"
