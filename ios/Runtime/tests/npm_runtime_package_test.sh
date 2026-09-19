#!/bin/sh
# Contract check for packaging the pinned npm CLI into the offline guest runtime.
set -eu

runtime_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stager="$runtime_dir/guest/image-build/openclaw-runtime/stage-npm.sh"
npm_tarball=${OPERATOR_TEST_NPM_TARBALL:?OPERATOR_TEST_NPM_TARBALL is required}
node_bin=${OPERATOR_TEST_NODE_BIN:?OPERATOR_TEST_NODE_BIN is required}
expected_sri='sha512-fYwb6ODSmHkqrJQQaCxY3M2lPf/mpgC7ik0HSzzIwG5CGtabRp4bNqikatvCoT42b5INQSqudVH0R7yVmC9hVg=='

test -x "$node_bin"
test -f "$npm_tarball"
test -x "$stager"

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
runtime_root="$test_root/runtime"
mkdir -p "$runtime_root/usr/local/bin" "$runtime_root/usr/local/lib/node_modules"
ln -s "$node_bin" "$runtime_root/usr/local/bin/node"

"$stager" "$npm_tarball" "$expected_sri" "$runtime_root"

test -L "$runtime_root/usr/local/bin/npm"
test -L "$runtime_root/usr/local/bin/npx"
test -f "$runtime_root/usr/local/lib/node_modules/npm/package.json"
test -x "$runtime_root/usr/local/bin/npm"
for public_path in \
  "$runtime_root/usr/local/lib/node_modules/npm" \
  "$runtime_root/usr/local/lib/node_modules/npm/bin" \
  "$runtime_root/usr/local/lib/node_modules/npm/package.json" \
  "$runtime_root/usr/local/lib/node_modules/npm/bin/npm-cli.js" \
  "$runtime_root/usr/local/lib/node_modules/npm/bin/npx-cli.js"; do
  mode=$(stat -f %Lp "$public_path")
  case "$mode" in
    ???|????) ;;
    *) exit 1 ;;
  esac
  test $((8#$mode & 0004)) -eq 4 || {
    printf 'FAIL: staged npm file is not readable by the guest: %s mode=%s\n' "$public_path" "$mode" >&2
    exit 1
  }
  if test -d "$public_path"; then
    test $((8#$mode & 0001)) -eq 1 || {
      printf 'FAIL: staged npm directory is not searchable by the guest: %s mode=%s\n' "$public_path" "$mode" >&2
      exit 1
    }
  fi
done
PATH="$runtime_root/usr/local/bin:$PATH" "$runtime_root/usr/local/bin/npm" --version | grep -Fx '10.9.8' >/dev/null

printf 'PASS: packaged npm runtime contract\n'
