#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-account-write-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/AccountWriteProofTests"
cp "$ios_dir/OperatorApp/Sources/connections/auth/OAuthTypes.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/auth/OAuthTransport.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/services/write/DirectAccountWriter.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/services/write/GoogleWorkspaceWrites.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/DirectAccountWriterTests.swift" "$scratch/Tests/AccountWriteProofTests/"
cp "$test_dir/GoogleWorkspaceWriterTests.swift" "$scratch/Tests/AccountWriteProofTests/"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"

swift test --package-path "$scratch" --scratch-path "$scratch/.build" -Xswiftc -warnings-as-errors
