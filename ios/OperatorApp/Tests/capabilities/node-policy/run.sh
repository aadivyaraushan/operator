#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-node-policy.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/ModelSetupProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/../../model-setup-restart/Package.template" > "$scratch/Package.swift"
source="$ios_dir/OperatorApp/Sources/capabilities/node/policy/NativeNodePolicySetup.swift"
# An empty module lets the first run report the missing implementation in tests.
if [ -f "$source" ]; then
    cp "$source" "$scratch/Sources/OperatorApp/"
else
    printf 'import Foundation\n' > "$scratch/Sources/OperatorApp/Empty.swift"
fi
cp "$test_dir/NativeNodePolicySetupTests.swift" "$scratch/Tests/ModelSetupProofTests/"
swift test --package-path "$scratch"
# Check that the production node route waits for this tested setup before connect.
rg -U -q 'guard try await self\.policySetup\.prepare\(\) else \{[\s\S]*?continue[\s\S]*?let connection = OpenClawNodeConnection' "$ios_dir/OperatorApp/Sources/capabilities/location/LocalLocationNodeGateway.swift"
echo 'PASS: native route waits for applied policy before connecting'
