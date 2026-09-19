#!/bin/sh
# Stage one pinned wacli executable into the read-only guest payload.
set -eu
umask 077

usage() {
  printf '%s\n' "usage: $0 WACLI_ARTIFACT WACLI_SHA256_MANIFEST OUTPUT_DIRECTORY" >&2
  exit 64
}

test "$#" -eq 3 || usage
artifact=$1
manifest=$2
output_dir=$3

test -f "$artifact" || {
  printf 'wacli artifact is missing: %s\n' "$artifact" >&2
  exit 66
}
test -f "$manifest" || {
  printf 'wacli checksum manifest is missing: %s\n' "$manifest" >&2
  exit 66
}
test ! -e "$output_dir" || {
  printf 'refusing to overwrite wacli payload: %s\n' "$output_dir" >&2
  exit 67
}

manifest_lines=$(wc -l <"$manifest" | tr -d ' ')
test "$manifest_lines" = 1 || {
  printf 'wacli checksum manifest must contain one wacli entry\n' >&2
  exit 65
}
read -r expected_digest expected_name unexpected_value <"$manifest"
test -n "$expected_digest" && test "$expected_name" = wacli && test -z "${unexpected_value:-}" || {
  printf 'wacli checksum manifest must contain one wacli entry\n' >&2
  exit 65
}
case "$expected_digest" in
  *[!0123456789abcdefABCDEF]*)
    printf 'wacli checksum has the wrong shape\n' >&2
    exit 65
    ;;
esac
test "${#expected_digest}" -eq 64 || {
  printf 'wacli checksum has the wrong shape\n' >&2
  exit 65
}
actual_digest=$(sha256sum "$artifact" | awk '{print $1}')
test "$actual_digest" = "$expected_digest" || {
  printf 'wacli artifact checksum mismatch\n' >&2
  exit 67
}

mkdir "$output_dir"
install -m 0755 "$artifact" "$output_dir/wacli"
cp "$manifest" "$output_dir/wacli.sha256"
(cd "$output_dir" && sha256sum -c wacli.sha256)
