#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: build.sh WACLI_SOURCE OUTPUT_DIRECTORY [simulator|device]' >&2
  exit 64
}

test "$#" -eq 2 -o "$#" -eq 3 || usage
source_dir=$1
output_dir=$2
slice=${3:-simulator}
case "$slice" in
  simulator) sdk_name=iphonesimulator; target=arm64-apple-ios18.0-simulator; pass_line=NATIVE_WHATSAPP_SIMULATOR_ARCHIVE_PASS ;;
  device) sdk_name=iphoneos; target=arm64-apple-ios18.0; pass_line=NATIVE_WHATSAPP_DEVICE_ARCHIVE_PASS ;;
  *) usage ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bridge_dir=$(CDPATH= cd -- "$script_dir/../bridge" && pwd)
read_dir=$(CDPATH= cd -- "$script_dir/../read" && pwd)
send_dir=$(CDPATH= cd -- "$script_dir/../send" && pwd)

expected_module=github.com/openclaw/wacli
expected_go=1.26.6
expected_mod_sha=b751d50a2f8bdd9b3cfc47fe8d3aa017a16c77b87f044b150493656177352116
expected_tree_sha=188bda00ba7e15d32ba78d81ef8b1463b784408eef2d909db32d9d1d5361ba39

test -f "$source_dir/go.mod" || { printf '%s\n' 'pinned wacli go.mod is missing' >&2; exit 66; }
test ! -e "$output_dir" || { printf '%s\n' 'refusing to replace native WhatsApp output' >&2; exit 73; }

module=$(awk '$1 == "module" { print $2; exit }' "$source_dir/go.mod")
go_version=$(awk '$1 == "go" { print $2; exit }' "$source_dir/go.mod")
mod_sha=$(shasum -a 256 "$source_dir/go.mod" | awk '{print $1}')
tree_sha=$(cd "$source_dir" && find . -type f ! -path './.git/*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
test "$module" = "$expected_module" || { printf '%s\n' 'wacli module does not match the pin' >&2; exit 65; }
test "$go_version" = "$expected_go" || { printf '%s\n' 'wacli Go version does not match the pin' >&2; exit 65; }
test "$mod_sha" = "$expected_mod_sha" || { printf '%s\n' 'wacli go.mod checksum does not match the pin' >&2; exit 65; }
test "$tree_sha" = "$expected_tree_sha" || { printf '%s\n' 'wacli source tree checksum does not match the pin' >&2; exit 65; }

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/operator-wacli-ios.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT INT TERM
staged_source=$work_dir/wacli
mkdir -p "$staged_source/cmd/wacli-ios-bridge"
cp -R "$source_dir/." "$staged_source/"
cp "$bridge_dir/main.go" "$bridge_dir/main_test.go" "$staged_source/cmd/wacli-ios-bridge/"
cp "$read_dir/read.go" "$read_dir/read_test.go" "$staged_source/cmd/wacli-ios-bridge/"
cp "$send_dir/send.go" "$send_dir/send_test.go" "$staged_source/cmd/wacli-ios-bridge/"

(
  cd "$staged_source"
  GOTOOLCHAIN=go1.26.6 go test -tags wacli ./cmd/wacli-ios-bridge
)

sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
clang=$(xcrun --sdk "$sdk_name" --find clang)
mkdir -p "$work_dir/output"
(
  cd "$staged_source"
  GOOS=ios GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=go1.26.6 CC="$clang" \
    CGO_CFLAGS="-isysroot $sdk -target $target -Wno-error=missing-braces" \
    CGO_LDFLAGS="-isysroot $sdk -target $target" \
    go build -tags sqlite_fts5,wacli -buildmode=c-archive \
      -trimpath -ldflags='-s -w -buildid=' \
      -o "$work_dir/output/libWacliBridge.a" ./cmd/wacli-ios-bridge
)

mkdir "$output_dir"
cp "$work_dir/output/libWacliBridge.a" "$work_dir/output/libWacliBridge.h" "$output_dir/"
printf 'wacli_source_tree_sha256=%s\nwacli_go_mod_sha256=%s\ngo_version=%s\ntarget=%s\n' \
  "$tree_sha" "$mod_sha" "$expected_go" "$target" > "$output_dir/build-info.txt"
printf '%s\n' "$pass_line"
