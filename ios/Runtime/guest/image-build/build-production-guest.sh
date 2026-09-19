#!/bin/sh
# Assemble checked, offline inputs for one production Alpine guest provisioning boot.
set -eu
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
guest_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
. "$guest_dir/definition/manifest.env"

usage() {
  printf '%s\n' "usage: $0 --alpine-qcow2 PATH --runtime-archive PATH --runtime-apks DIRECTORY --output-qcow2 PATH --work-dir DIRECTORY [--wacli PATH] [--run-qemu]" >&2
  exit 64
}

alpine_qcow2=
runtime_archive=
runtime_apks=
output_qcow2=
work_dir=
run_qemu=false
wacli_artifact=
while test "$#" -gt 0; do
  case "$1" in
    --alpine-qcow2|--runtime-archive|--runtime-apks|--output-qcow2|--work-dir|--wacli)
      test "$#" -ge 2 || usage
      case "$1" in
        --alpine-qcow2) alpine_qcow2=$2 ;;
        --runtime-archive) runtime_archive=$2 ;;
        --runtime-apks) runtime_apks=$2 ;;
        --output-qcow2) output_qcow2=$2 ;;
        --work-dir) work_dir=$2 ;;
        --wacli) wacli_artifact=$2 ;;
      esac
      shift 2
      ;;
    --run-qemu)
      run_qemu=true
      shift
      ;;
    *) usage ;;
  esac
done

test -n "$alpine_qcow2" && test -n "$runtime_archive" && test -n "$runtime_apks" && \
  test -n "$output_qcow2" && test -n "$work_dir" || usage
test -f "$alpine_qcow2" || {
  printf 'clean Alpine qcow2 is missing: %s\n' "$alpine_qcow2" >&2
  exit 66
}
test -f "$runtime_archive" || {
  printf 'checked OpenClaw runtime archive is missing: %s\n' "$runtime_archive" >&2
  exit 66
}
test -d "$runtime_apks" || {
  printf 'checked runtime APK directory is missing: %s\n' "$runtime_apks" >&2
  exit 66
}
if test -n "$wacli_artifact"; then
  test -f "$wacli_artifact" || {
    printf 'checked wacli artifact is missing: %s\n' "$wacli_artifact" >&2
    exit 66
  }
fi
test "$(basename -- "$runtime_archive")" = "$OPENCLAW_RUNTIME_ARCHIVE" || {
  printf 'runtime archive must be named by the manifest: %s\n' "$OPENCLAW_RUNTIME_ARCHIVE" >&2
  exit 67
}
test ! -e "$output_qcow2" || {
  printf 'refusing to overwrite: %s\n' "$output_qcow2" >&2
  exit 67
}
test ! -e "$work_dir" || {
  printf 'refusing to overwrite: %s\n' "$work_dir" >&2
  exit 67
}

printf '%s  %s\n' "$ALPINE_IMAGE_SHA512" "$alpine_qcow2" | sha512sum -c -
test "$(stat -c %s "$runtime_archive")" = "$OPENCLAW_RUNTIME_SIZE_BYTES" || {
  printf 'runtime archive size does not match the manifest\n' >&2
  exit 67
}
printf '%s  %s\n' "$OPENCLAW_RUNTIME_SHA512" "$runtime_archive" | sha512sum -c -

apk_manifest="$guest_dir/definition/runtime-apks.sha256"
test -f "$apk_manifest" || {
  printf 'runtime APK manifest is missing: %s\n' "$apk_manifest" >&2
  exit 66
}
expected_apks=0
while read -r apk_digest apk_name; do
  test -n "$apk_digest" && test -n "$apk_name" || {
    printf 'runtime APK manifest has an invalid entry\n' >&2
    exit 67
  }
  case "$apk_name" in
    *.apk) ;;
    *) printf 'runtime APK manifest has an invalid filename\n' >&2; exit 67 ;;
  esac
  test -f "$runtime_apks/$apk_name" || {
    printf 'runtime APK is missing: %s\n' "$apk_name" >&2
    exit 66
  }
  expected_apks=$((expected_apks + 1))
done <"$apk_manifest"
actual_apks=0
for apk in "$runtime_apks"/*.apk; do
  test -f "$apk" || continue
  actual_apks=$((actual_apks + 1))
done
test "$actual_apks" -eq "$expected_apks" || {
  printf 'runtime APK directory contains an unexpected APK\n' >&2
  exit 67
}
(cd "$runtime_apks" && sha256sum -c "$apk_manifest")

mkdir "$work_dir"
inputs_dir="$work_dir/inputs"
payload_dir="$work_dir/payload"
payload_guest_dir="$payload_dir/guest"
payload_apks_dir="$payload_dir/runtime-apks"
payload_wacli_dir="$payload_dir/wacli"
seed_dir="$work_dir/nocloud"
seed_iso="$work_dir/operator-nocloud.iso"
payload_iso="$work_dir/operator-payload.iso"
mkdir -p "$inputs_dir" "$payload_guest_dir" "$payload_apks_dir" "$seed_dir"
cp "$alpine_qcow2" "$inputs_dir/alpine-clean.qcow2"
cp "$runtime_archive" "$payload_dir/$OPENCLAW_RUNTIME_ARCHIVE"
cp -R "$guest_dir/definition" "$guest_dir/first-boot" "$guest_dir/runtime-start" "$guest_dir/skills" "$payload_guest_dir/"
while read -r apk_digest apk_name; do
  cp "$runtime_apks/$apk_name" "$payload_apks_dir/$apk_name"
done <"$apk_manifest"
(cd "$payload_apks_dir" && sha256sum -c "$apk_manifest")
if test -n "$wacli_artifact"; then
  "$script_dir/stage-wacli.sh" "$wacli_artifact" \
    "$guest_dir/definition/wacli.sha256" "$payload_wacli_dir"
fi

cat >"$seed_dir/meta-data" <<'EOF'
instance-id: operator-production-provisioning
local-hostname: operator
EOF
cat >"$seed_dir/user-data" <<EOF
#cloud-config
no_ssh_fingerprints: true
runcmd:
  - |
    set -eu
    provisioning_status=1
    trap 'if test "\$provisioning_status" -eq 0; then printf "OPERATOR_PROVISIONING_COMPLETE\\n" >/dev/ttyS0; else printf "OPERATOR_PROVISIONING_FAILED\\n" >/dev/ttyS0; fi; sync; poweroff' EXIT
    mkdir -p /mnt/operator-payload
    mount -o ro -L OPERATOR_PAYLOAD /mnt/operator-payload
    /mnt/operator-payload/guest/first-boot/provision-guest.sh /mnt/operator-payload/$OPENCLAW_RUNTIME_ARCHIVE /mnt/operator-payload/runtime-apks${wacli_artifact:+ /mnt/operator-payload/wacli}
    rm -f /root/.ssh/authorized_keys /home/alpine/.ssh/authorized_keys
    provisioning_status=0
EOF
mkisofs -output "$seed_iso" -volid cidata -joliet -rock "$seed_dir/meta-data" "$seed_dir/user-data"
mkisofs -output "$payload_iso" -volid OPERATOR_PAYLOAD -joliet -rock "$payload_dir"

"$script_dir/build-clean-image.sh" "$inputs_dir/alpine-clean.qcow2" "$output_qcow2"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

printf '%s\n' 'Provision with:'
printf '%s' 'qemu-system-x86_64'
for qemu_argument in -m 2048 -smp 2 \
  -drive "file=$output_qcow2,if=virtio,format=qcow2" \
  -drive "file=$seed_iso,media=cdrom,readonly=on,format=raw" \
  -drive "file=$payload_iso,media=cdrom,readonly=on,format=raw" \
  -nographic -no-reboot; do
  printf ' '
  shell_quote "$qemu_argument"
done
printf '\n'
if test "$run_qemu" = true; then
  provision_log=$work_dir/provision-console.log
  qemu-system-x86_64 -m 2048 -smp 2 \
    -drive "file=$output_qcow2,if=virtio,format=qcow2" \
    -drive "file=$seed_iso,media=cdrom,readonly=on,format=raw" \
    -drive "file=$payload_iso,media=cdrom,readonly=on,format=raw" \
    -display none -monitor none -serial "file:$provision_log" -no-reboot
  grep -Fq 'OPERATOR_PROVISIONING_COMPLETE' "$provision_log" || {
    printf 'provisioning completion marker is missing: %s\n' "$provision_log" >&2
    exit 69
  }
fi
