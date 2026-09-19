#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/native-whatsapp-swift.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

swiftc -parse-as-library -emit-module -emit-library -module-name OperatorCore \
  "$root/OperatorCore/Sources/OperatorCore/gateway/whatsapp/link/GatewayWhatsAppLinkTypes.swift" \
  "$root/Runtime/native-whatsapp/swift-tests/fixtures/gateway_types.swift" \
  -emit-module-path "$work/OperatorCore.swiftmodule" -o "$work/libOperatorCore.dylib"

swiftc -parse-as-library -I "$work" -L "$work" -lOperatorCore \
  "$root/Runtime/native-whatsapp/swift-tests/fixtures/flow_protocol.swift" \
  "$root/OperatorApp/Sources/capabilities/whatsapp/link/NativeWhatsAppLinkClient.swift" \
  "$root/OperatorApp/Sources/capabilities/whatsapp/read/NativeWhatsAppReadClient.swift" \
  "$root/OperatorApp/Sources/capabilities/whatsapp/read/ForegroundWhatsAppReadService.swift" \
  "$root/Runtime/native-whatsapp/swift-tests/client_test.swift" \
  "$root/Runtime/native-whatsapp/swift-tests/c_stubs.c" \
  -o "$work/native-whatsapp-client-test"

DYLD_LIBRARY_PATH="$work" "$work/native-whatsapp-client-test"
