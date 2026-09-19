#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-maps-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/MapsProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"
cp "$ios_dir/OperatorApp/Sources/capabilities/maps/ForegroundMapsService.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/ForegroundMapsServiceTests.swift" "$scratch/Tests/MapsProofTests/"
mkdir -p "$scratch/module-cache"
CLANG_MODULE_CACHE_PATH="$scratch/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache" \
  swift test --package-path "$scratch" --scratch-path "$scratch/.build"
