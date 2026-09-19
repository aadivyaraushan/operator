#!/bin/bash
set -euo pipefail
ios_dir="$(cd "$(dirname "$0")/../../../.." && pwd)"
scratch="$(mktemp -d /private/tmp/operator-host-checks.XXXXXX)"
cp "$ios_dir/OperatorApp/Tests/runtime/embedded/HostChecks.template" "$scratch/HostChecks.swift"
swiftc -module-cache-path /private/tmp/operator-host-module-cache -swift-version 6 "$ios_dir/OperatorApp/Sources/runtime/embedded/endpoint/LoopbackPort.swift" "$ios_dir/OperatorApp/Sources/runtime/embedded/EmbeddedRuntimeHost.swift" "$scratch/HostChecks.swift" -o "$scratch/checks"
"$scratch/checks"
swiftc -module-cache-path /private/tmp/operator-host-module-cache -swift-version 6 "$ios_dir/OperatorApp/Sources/runtime/embedded/endpoint/LoopbackPort.swift" "$ios_dir/OperatorApp/Tests/runtime/embedded/endpoint/LoopbackPortChecks.swift" -o "$scratch/port-checks"
"$scratch/port-checks"
