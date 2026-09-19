#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
utm_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$utm_dir/manifest.env"

[ "$#" -eq 1 ] || {
    printf 'Usage: %s /path/to/pinned-UTM-source\n' "$(basename "$0")" >&2
    exit 2
}

source_root=$1
[ -d "$source_root/.git" ] || {
    printf 'error: UTM checkout is missing: %s\n' "$source_root" >&2
    exit 2
}

scratch=$(mktemp -d /private/tmp/operator-restore-result-test.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
git clone --quiet --no-checkout "$source_root" "$scratch/utm"
git -C "$scratch/utm" checkout --quiet --detach "$UTM_COMMIT"
"$utm_dir/scripts/apply-utm-restore-result.sh" "$scratch/utm"
"$test_dir/restore-result-contract_test.sh" "$scratch/utm"
