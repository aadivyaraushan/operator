#!/bin/sh
# Stage npm 10.9.8 from https://registry.npmjs.org/npm/-/npm-10.9.8.tgz
# into an already checked offline Node runtime.
set -eu
umask 077

usage() {
  printf '%s\n' "usage: $0 NPM_TARBALL NPM_SHA512_SRI RUNTIME_ROOT" >&2
  exit 64
}

test "$#" = 3 || usage
npm_tarball=$1
expected_sri=$2
runtime_root=$3
expected_sri_prefix='sha512-'
expected_digest='fYwb6ODSmHkqrJQQaCxY3M2lPf/mpgC7ik0HSzzIwG5CGtabRp4bNqikatvCoT42b5INQSqudVH0R7yVmC9hVg=='

test -f "$npm_tarball" || {
  printf 'npm archive is missing: %s\n' "$npm_tarball" >&2
  exit 66
}
test -d "$runtime_root/usr/local/bin" && test -d "$runtime_root/usr/local/lib/node_modules" || {
  printf 'runtime root lacks the packaged Node layout: %s\n' "$runtime_root" >&2
  exit 66
}
test "$expected_sri" = "$expected_sri_prefix$expected_digest" || {
  printf 'npm archive digest pin does not match npm 10.9.8\n' >&2
  exit 65
}
actual_digest=$(openssl dgst -sha512 -binary "$npm_tarball" | openssl base64 -A)
test "$actual_digest" = "$expected_digest" || {
  printf 'npm archive digest mismatch\n' >&2
  exit 67
}

tar -tzf "$npm_tarball" | awk '
  $0 !~ /^package\// || $0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /^\// { exit 1 }
  END { if (NR == 0) exit 1 }
' || {
  printf 'npm archive contains an unsafe path\n' >&2
  exit 65
}

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/operator-npm-10.9.8.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT HUP INT TERM
tar -xzf "$npm_tarball" -C "$staging_root"
package_root=$staging_root/package
test -f "$package_root/package.json" && test -f "$package_root/bin/npm-cli.js" && test -f "$package_root/bin/npx-cli.js" || {
  printf 'npm archive has no runnable npm package\n' >&2
  exit 68
}
grep -Fqx '  "version": "10.9.8",' "$package_root/package.json" && \
  grep -Fqx '    "node": "^18.17.0 || >=20.5.0"' "$package_root/package.json" || {
  printf 'npm archive version or Node engine is not pinned npm 10.9.8\n' >&2
  exit 68
}

npm_destination=$runtime_root/usr/local/lib/node_modules/npm
npm_bin=$runtime_root/usr/local/bin/npm
npx_bin=$runtime_root/usr/local/bin/npx
test ! -e "$npm_destination" && test ! -e "$npm_bin" && test ! -e "$npx_bin" || {
  printf 'refusing to overwrite packaged npm paths\n' >&2
  exit 67
}
mv "$package_root" "$npm_destination"
find "$npm_destination" -type d -exec chmod 0755 {} +
find "$npm_destination" -type f -exec chmod 0644 {} +
chmod 0755 "$npm_destination/bin/npm-cli.js" "$npm_destination/bin/npx-cli.js"
ln -s ../lib/node_modules/npm/bin/npm-cli.js "$npm_bin"
ln -s ../lib/node_modules/npm/bin/npx-cli.js "$npx_bin"
