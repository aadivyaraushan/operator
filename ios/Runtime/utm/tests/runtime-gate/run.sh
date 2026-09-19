#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file=${1:-"$test_dir/../../overlay/UTMApp.swift"}
scratch=$(mktemp -d /private/tmp/operator-runtime-gate.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
awk '
FILENAME == ARGV[1] {
 if ($0 ~ /^    private func activateRuntime\(/) capture=1
 if(capture) {gsub(/private func activateRuntime/, "func exercise"); method=method $0 "\n"; if($0 ~ /^    }$/)capture=0}
 next
}
$0 == "// METHOD" {if(!length(method))exit 2; printf "%s",method;next}
{print}
' "$source_file" "$test_dir/Tests.swift" > "$scratch/Tests.swift"
swiftc -parse-as-library -module-cache-path "$scratch/cache" "$scratch/Tests.swift" -o "$scratch/test"
"$scratch/test"
