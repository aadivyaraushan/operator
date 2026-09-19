#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-reminders-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/RemindersProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"
cp "$ios_dir/OperatorApp/Sources/capabilities/reminders/ForegroundRemindersService.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/ForegroundRemindersServiceTests.swift" "$scratch/Tests/RemindersProofTests/"
mkdir -p "$scratch/module-cache"
CLANG_MODULE_CACHE_PATH="$scratch/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache" \
  swift test --package-path "$scratch" --scratch-path "$scratch/.build"
