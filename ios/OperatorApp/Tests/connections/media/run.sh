#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$test_dir/../../../.." && pwd)
scratch=$(mktemp -d /private/tmp/operator-media-services-proof.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

mkdir -p "$scratch/Sources/OperatorApp" "$scratch/Tests/MediaServicesProofTests"
cp "$ios_dir/OperatorApp/Sources/connections/auth/OAuthTransport.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/handoff/ForegroundAppHandoffService.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/media/network/PublicMediaURLPolicy.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/media/network/PublicMediaHTTPTransport.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/media/youtube/YouTubeMediaServices.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/media/podcasts/PodcastMediaServices.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/media/node/ForegroundMediaNodeService.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/connections/media/presentation/InAppMediaOpener.swift" "$scratch/Sources/OperatorApp/"
cp "$ios_dir/OperatorApp/Sources/capabilities/node/ForegroundNodeCommandRouter.swift" "$scratch/Sources/OperatorApp/"
cp "$test_dir/MediaServicesTests.swift" "$scratch/Tests/MediaServicesProofTests/"
sed "s|CORE_PACKAGE_PATH|$ios_dir/OperatorCore|" "$test_dir/Package.template" > "$scratch/Package.swift"

swift test --package-path "$scratch" --scratch-path "$scratch/.build" -Xswiftc -warnings-as-errors
