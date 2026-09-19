#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-model-setup-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/ModelSetupProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"
cp "$ios_dir/OperatorApp/Sources/model-setup/ModelSetupContracts.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/model-setup/LocalModelSetupGateway.swift" "$scratch/Sources/OperatorApp/"
# The app model is unchanged; UIKit presentation alone is outside this macOS check.
sed '/^struct ModelSetupSheet:/,$d; /^import UIKit$/d' "$ios_dir/OperatorApp/Sources/model-setup/ModelSetupFlow.swift" > "$scratch/Sources/OperatorApp/ModelSetupFlow.swift"
cp "$ios_dir/OperatorApp/Tests/ModelSetupModelTests.swift" "$scratch/Tests/ModelSetupProofTests/"
cp "$test_dir/../model-setup-gateway/LocalModelSetupGatewayTests.swift" "$scratch/Tests/ModelSetupProofTests/"
swift test --package-path "$scratch"
