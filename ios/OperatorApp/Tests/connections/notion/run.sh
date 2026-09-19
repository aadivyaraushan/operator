#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-notion-mcp-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/NotionMCPProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"
cp "$ios_dir/OperatorApp/Sources/connections/auth/OAuthTransport.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/notion/NotionMCPClient.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/NotionMCPClientTests.swift" "$scratch/Tests/NotionMCPProofTests/"
mkdir -p "$scratch/module-cache"
CLANG_MODULE_CACHE_PATH="$scratch/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache" \
  swift test --package-path "$scratch" --scratch-path "$scratch/.build" -Xswiftc -warnings-as-errors
