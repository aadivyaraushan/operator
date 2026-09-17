#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-handoff-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/HandoffProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"
cp "$ios_dir/OperatorApp/Sources/capabilities/handoff/ForegroundAppHandoffService.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/handoff/AppLaunchByName.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/ForegroundAppHandoffServiceTests.swift" "$scratch/Tests/HandoffProofTests/"
swift test --package-path "$scratch" --scratch-path "$scratch/.build"
