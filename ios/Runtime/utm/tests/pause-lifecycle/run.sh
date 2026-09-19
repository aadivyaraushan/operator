#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file="$test_dir/../../overlay/UTMApp.swift"
scratch=$(mktemp -d /private/tmp/operator-pause-lifecycle.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
awk '
FILENAME == ARGV[1] {
    if ($0 ~ /^    func (start\(credentials:|saveSnapshot\(\))/) in_method = 1
    if (in_method) { methods = methods $0 "\n"; if ($0 ~ /^    }$/) in_method = 0 }
    if ($0 ~ /^private enum OperatorVMAdapterError:/) in_error = 1
    if (in_error) { errors = errors $0 "\n"; if ($0 == "}") in_error = 0 }
    next
}
$0 == "// INSERT_METHODS" { if (!length(methods)) exit 2; printf "%s", methods; next }
$0 == "// INSERT_ERRORS" { if (!length(errors)) exit 2; printf "%s", errors; next }
{ print }
' "$source_file" "$test_dir/PauseLifecycleTests.swift" > "$scratch/Tests.swift"
swiftc -parse-as-library -module-cache-path "$scratch/module-cache" "$scratch/Tests.swift" -o "$scratch/tests"
"$scratch/tests" "$source_file"
