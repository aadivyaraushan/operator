#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-connection-discovery-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/ConnectionDiscoveryProofTests"
cp "$ios_dir/OperatorApp/Sources/connections/auth/OAuthTypes.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/auth/OAuthTransport.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/services/read/DirectAccountReader.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/services/write/DirectAccountWriter.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/services/write/GoogleWorkspaceWrites.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/handoff/ForegroundAppHandoffService.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/discovery/ForegroundConnectionDiscoveryService.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/ConnectionDiscoveryServiceTests.swift" "$scratch/Tests/ConnectionDiscoveryProofTests/"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"
swift test --package-path "$scratch" --scratch-path "$scratch/.build" -Xswiftc -warnings-as-errors
