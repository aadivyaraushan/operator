#!/bin/sh
# Make a fresh qcow2 copy only from a caller-verified clean Alpine source image.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/../definition/manifest.env"

usage() {
  printf 'usage: %s SOURCE.qcow2 OUTPUT.qcow2\n' "$0" >&2
  exit 64
}

test "$#" -eq 2 || usage
source_image=$1
output_image=$2
case "$ALPINE_IMAGE_SHA512" in
  *[!0123456789abcdefABCDEF]*)
    printf 'ALPINE_IMAGE_SHA512 must be exactly 128 hexadecimal characters\n' >&2
    exit 65
    ;;
esac
test "${#ALPINE_IMAGE_SHA512}" -eq 128 || {
  printf 'ALPINE_IMAGE_SHA512 must be exactly 128 hexadecimal characters\n' >&2
  exit 65
}
verified_digest=$(printf '%s' "$ALPINE_IMAGE_SHA512" | tr 'A-F' 'a-f')
case "$verified_digest" in
  "$ALPINE_IMAGE_SHA512_PREFIX"*) ;;
  *)
    printf 'ALPINE_IMAGE_SHA512 does not match the recorded Alpine digest prefix\n' >&2
    exit 65
    ;;
esac

test -f "$source_image" || {
  printf 'clean source image not found: %s\n' "$source_image" >&2
  exit 66
}
test ! -e "$output_image" || {
  printf 'refusing to overwrite: %s\n' "$output_image" >&2
  exit 67
}

printf '%s  %s\n' "$verified_digest" "$source_image" | sha512sum -c -
mkdir -p "$(dirname -- "$output_image")"
qemu-img convert -f qcow2 -O qcow2 "$source_image" "$output_image"
qemu-img resize "$output_image" "$GUEST_DISK_SIZE"
qemu-img info "$output_image"
