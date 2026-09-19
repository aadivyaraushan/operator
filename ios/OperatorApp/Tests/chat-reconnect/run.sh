#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-chat-reconnect.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/ModelSetupProofTests"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/../model-setup-restart/Package.template" > "$scratch/Package.swift"
for source in runtime/ChatContracts.swift runtime/LocalOpenClawChatGateway.swift chat/ChatSessionModel.swift chat/ChatActivity.swift runtime/continuation/ReplyContinuation.swift; do
    cp "$ios_dir/OperatorApp/Sources/$source" "$scratch/Sources/OperatorApp/"
done
# Include the actual message text formatter used by the app. SwiftUI is not
# available in this host-only harness, but this enum only needs Foundation.
printf 'import Foundation\nimport OperatorCore\n\n' > "$scratch/Sources/OperatorApp/ChatMessageText.swift"
awk '
/^enum ChatMessageText/ { formatter=1 }
formatter && /^struct ChatScreen/ { formatter=0 }
formatter { print }
' "$ios_dir/OperatorApp/Sources/chat/ChatScreen.swift" >> "$scratch/Sources/OperatorApp/ChatMessageText.swift"
# Before the readiness fix these methods lived only in the UTM overlay. Include
# that actual implementation for the red run, not a substitute implementation.
awk '
/^private final class OperatorRuntimeReadiness/ { print "@MainActor"; print; readiness=1; next }
readiness { print; if ($0 == "}") readiness=0; next }
/^extension ChatSessionModel/ { extensionBody=1 }
extensionBody { print; if ($0 == "}") extensionBody=0 }
' "$ios_dir/Runtime/utm/overlay/UTMApp.swift" >> "$scratch/Sources/OperatorApp/ChatSessionModel.swift"
# The extracted coordinator uses Foundation, not the iOS app's UIKit import.
sed -e '/^@main/,$d' -e '/^import UIKit$/d' "$ios_dir/OperatorApp/Sources/app/OperatorApp.swift" > "$scratch/Sources/OperatorApp/ForegroundRuntimeCoordinator.swift"
# Microphone access is outside this test; retain the real dictation model and use an inert service.
sed '/^final class AppleOnDeviceDictationService:/,$d' "$ios_dir/OperatorApp/Sources/dictation/OfflineDictation.swift" > "$scratch/Sources/OperatorApp/OfflineDictation.swift"
sed '$d' "$scratch/Sources/OperatorApp/OfflineDictation.swift" > "$scratch/Sources/OperatorApp/OfflineDictation.tmp"
mv "$scratch/Sources/OperatorApp/OfflineDictation.tmp" "$scratch/Sources/OperatorApp/OfflineDictation.swift"
cp "$test_dir/DictationService.template" "$scratch/Sources/OperatorApp/DictationService.swift"
cp "$ios_dir/OperatorApp/Tests/ChatSessionModelTests.swift" "$scratch/Tests/ModelSetupProofTests/"
cp "$test_dir/LocalOpenClawChatGatewayTests.swift" "$scratch/Tests/ModelSetupProofTests/"
swift test --package-path "$scratch"
