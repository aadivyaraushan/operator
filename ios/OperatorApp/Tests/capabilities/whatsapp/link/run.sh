#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-whatsapp-link-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/WhatsAppLinkProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$ios_dir/OperatorApp/Tests/model-setup-restart/Package.template" > "$scratch/Package.swift"
source="$ios_dir/OperatorApp/Sources/capabilities/whatsapp/link/WhatsAppLinkFlow.swift"
if [ -f "$source" ]; then
    cp "$source" "$scratch/Sources/OperatorApp/"
else
    printf 'import Foundation\n' > "$scratch/Sources/OperatorApp/Empty.swift"
fi
cp "$test_dir/WhatsAppLinkFlowTests.swift" "$scratch/Tests/WhatsAppLinkProofTests/"
swift test --package-path "$scratch"
