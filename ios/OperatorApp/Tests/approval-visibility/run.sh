#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
screen="$test_dir/../../Sources/chat/ChatScreen.swift"
# This checks the real SwiftUI wiring; a Simulator check must prove visibility.
rg -U -q '\.onChange\(of: self\.model\.approvals\.map\(\\\.id\)\) \{[\s\S]*?proxy\.scrollTo\("approval-\\\(id\)", anchor: \.bottom\)' "$screen" || {
    echo 'FAIL: new approvals do not scroll to their card'
    exit 1
}
rg -F -q '.id("approval-\(approval.id)")' "$screen" || {
    echo 'FAIL: approval scroll target does not match the card identity'
    exit 1
}
echo 'PASS: approval visibility wiring; real Simulator visibility still required'
