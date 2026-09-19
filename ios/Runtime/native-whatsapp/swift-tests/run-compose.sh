#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/native-whatsapp-compose.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

swiftc -parse-as-library -emit-module -emit-library -module-name OperatorCore \
  "$root/Runtime/native-whatsapp/swift-tests/fixtures/gateway_types.swift" \
  -emit-module-path "$work/OperatorCore.swiftmodule" -o "$work/libOperatorCore.dylib"

swiftc -parse-as-library -I "$work" -L "$work" -lOperatorCore \
  "$root/OperatorApp/Sources/capabilities/whatsapp/send/ForegroundWhatsAppComposeService.swift" \
  "$root/OperatorApp/Sources/capabilities/whatsapp/send/NativeWhatsAppSendClient.swift" \
  "$root/Runtime/native-whatsapp/swift-tests/compose_test.swift" \
  "$root/Runtime/native-whatsapp/swift-tests/c_stubs.c" \
  -o "$work/native-whatsapp-compose-test"

DYLD_LIBRARY_PATH="$work" "$work/native-whatsapp-compose-test"
