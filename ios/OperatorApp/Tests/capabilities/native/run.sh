#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-native-read-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/NativeReadProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"
for source in \
  capabilities/photos/ForegroundPhotosService.swift \
  capabilities/music/ForegroundMusicService.swift \
  capabilities/weather/ForegroundWeatherService.swift \
  capabilities/device/ForegroundDeviceService.swift \
  capabilities/reminders/ForegroundRemindersService.swift \
  capabilities/contacts/ForegroundContactsService.swift
do
  cp "$ios_dir/OperatorApp/Sources/$source" "$scratch/Sources/OperatorApp/"
done
cp "$test_dir/NativeReadServiceTests.swift" "$scratch/Tests/NativeReadProofTests/"
mkdir -p "$scratch/module-cache"
CLANG_MODULE_CACHE_PATH="$scratch/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache" \
  swift test --package-path "$scratch" --scratch-path "$scratch/.build"
