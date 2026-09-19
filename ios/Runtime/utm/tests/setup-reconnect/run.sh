#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d /private/tmp/operator-setup-reconnect.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
awk '
FILENAME == ARGV[1] {
 if ($0 ~ /^    private func (restart|reconnect)AfterModelSetup\(/) capture=1
 if(capture) {gsub(/private func (restart|reconnect)AfterModelSetup/, "func exercise"); method=method $0 "\n"; if($0 ~ /^    }$/)capture=0}
 next
}
$0 == "// METHOD" {if(!length(method))exit 2; printf "%s",method;next}
{print}
' "$test_dir/../../overlay/UTMApp.swift" "$test_dir/Tests.swift" > "$scratch/Tests.swift"
swiftc -parse-as-library -module-cache-path "$scratch/cache" "$scratch/Tests.swift" -o "$scratch/test"
"$scratch/test"
