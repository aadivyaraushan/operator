#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-youtube-key-setup-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/YouTubeAPIKeySetupProofTests"
cp "$ios_dir/OperatorApp/Sources/connections/media/youtube/YouTubeAPIKeySetup.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/YouTubeAPIKeySetupTests.swift" "$scratch/Tests/YouTubeAPIKeySetupProofTests/"
cp "$test_dir/Package.template" "$scratch/Package.swift"

swift test --package-path "$scratch" --scratch-path "$scratch/.build" -Xswiftc -warnings-as-errors
