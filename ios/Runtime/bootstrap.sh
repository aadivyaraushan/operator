#!/bin/sh
set -eu
#
# One command from a clone to the three generated inputs the Xcode project
# needs. Before this existed the steps lived only in a handoff document, which
# is why that document had to admit no clean-clone bootstrap had ever been
# executed.
#
# It generates nothing itself. It checks prerequisites, checks the artifacts
# against their pins, and then calls the two staging scripts that already
# exist, so there is one description of how to build each input rather than
# two that can disagree.
#
# Usage:
#   bootstrap.sh --check
#   bootstrap.sh --pin NODEMOBILE
#   bootstrap.sh NODEMOBILE OPENCLAW_PACKAGE WACLI_SOURCE
#
# --check reports what is present, what is pinned and what would be built,
# and writes nothing. It is the mode that runs on a machine without Xcode.

usage() {
  printf '%s\n' 'usage: bootstrap.sh [--check] [NODEMOBILE OPENCLAW_PACKAGE WACLI_SOURCE]' >&2
  printf '%s\n' '       bootstrap.sh --pin NODEMOBILE' >&2
  printf '%s\n' '  NODEMOBILE        NodeMobile.xcframework directory, or the release .zip' >&2
  printf '%s\n' '  OPENCLAW_PACKAGE  openclaw@2026.9.1 directory with node_modules installed' >&2
  printf '%s\n' '  WACLI_SOURCE      wacli v0.17.1 source tree' >&2
  exit 64
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir=$ios_dir/build
node_output=$build_dir/native-node/NodeMobile.xcframework
runtime_output=$build_dir/native-node/runtime
whatsapp_output=$build_dir/native-whatsapp
whatsapp_device_output=$build_dir/native-whatsapp-device

# Recorded 2026-09-11 from nodejs-mobile-ios-24.18.0-0.zip, downloaded
# directly from the GitHub release named in Runtime/DEPENDENCIES.md. Before
# this the value was "unpinned" and the script refused to stage the framework
# at all, which is why no second machine could build.
expected_nodemobile_sha=0d60c9ce613559bd4377d60450199e7d3aece8715143951a86fc5fd2870a4662
expected_openclaw_version=2026.9.1

tree_sha() {
  (cd "$1" && find . -type f ! -path './.git/*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
}

# Resolves the framework directory from any of the three shapes someone
# plausibly has: the release .zip, the extracted NodeMobile.xcframework
# itself, or the directory they extracted it into. Prints nothing when the
# path holds no framework, so a wrong directory is refused rather than
# hashed - a checksum computed over the wrong tree is worse than none,
# because it looks like it worked.
resolve_framework() {
  case "$1" in
    *.zip)
      unzip -q "$1" -d "$2"
      find "$2" -type d -name 'NodeMobile.xcframework' -print | head -n 1
      ;;
    *)
      case "$(basename "$1")" in
        NodeMobile.xcframework) test -d "$1" && printf '%s\n' "$1" ;;
        *) find "$1" -maxdepth 2 -type d -name 'NodeMobile.xcframework' -print 2>/dev/null | head -n 1 ;;
      esac
      ;;
  esac
}

# An xcframework always carries an Info.plist. Requiring it rejects an empty
# directory that merely has the right name.
is_framework() {
  test -n "$1" && test -d "$1" && test -f "$1/Info.plist"
}

# --pin computes the checksum and writes nothing. It exists so the person who
# obtains the prerelease artifact can record its hash from whatever machine
# they downloaded it on, without needing Xcode to do it.
if test "${1-}" = '--pin'; then
  test "$#" -eq 2 || usage
  pin_work=$(mktemp -d "${TMPDIR:-/tmp}/operator-pin.XXXXXX")
  trap 'rm -rf "$pin_work"' EXIT INT TERM
  framework=$(resolve_framework "$2" "$pin_work")
  is_framework "$framework" || {
    printf '%s\n' 'no NodeMobile.xcframework found at that path' >&2
    exit 66
  }
  printf 'nodemobile_sha256=%s\n' "$(tree_sha "$framework")"
  printf '%s\n' 'Record this in bootstrap.sh (expected_nodemobile_sha) and Runtime/DEPENDENCIES.md.'
  printf '%s\n' 'BOOTSTRAP_PIN_PASS'
  exit 0
fi

check_only=no
if test "${1-}" = '--check'; then
  check_only=yes
  shift
fi

if test "$check_only" = 'no' && test "$#" -ne 3; then usage; fi
if test "$check_only" = 'yes' && test "$#" -ne 0 && test "$#" -ne 3; then usage; fi

nodemobile=${1-}
openclaw=${2-}
wacli=${3-}

status=0
note() { printf '%s\n' "$1"; }
bad() { printf '%s\n' "$1" >&2; status=1; }

# ---- prerequisites -------------------------------------------------------

note '== toolchain =='
if command -v node >/dev/null 2>&1; then note "node        $(node --version)"; else bad 'node        MISSING'; fi
if command -v go >/dev/null 2>&1; then note "go          $(go version | awk '{print $3}')"; else bad 'go          MISSING'; fi
if command -v shasum >/dev/null 2>&1; then note 'shasum      present'; else bad 'shasum      MISSING'; fi
if xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
  note "iOS SDK     $(xcrun --sdk iphonesimulator --show-sdk-path)"
else
  bad 'iOS SDK     MISSING - Command Line Tools alone cannot build this; full Xcode is required'
fi

# ---- outputs -------------------------------------------------------------

note ''
note '== outputs =='
for output in "$node_output" "$runtime_output" "$whatsapp_output" "$whatsapp_device_output"; do
  if test -e "$output"; then
    if test "$check_only" = 'yes'; then
      note "present     $output"
    else
      bad "refusing to replace an existing output: $output"
      status=73
    fi
  else
    note "to build    $output"
  fi
done

# ---- inputs --------------------------------------------------------------

if test -n "$nodemobile$openclaw$wacli"; then
  note ''
  note '== inputs =='

  if test -e "$nodemobile"; then
    note "NodeMobile  $nodemobile"
  else
    bad "NodeMobile  MISSING at $nodemobile"
  fi

  if test -f "$openclaw/package.json"; then
    version=$(node -e 'process.stdout.write(require(process.argv[1]).version||"")' "$openclaw/package.json" 2>/dev/null || printf 'unreadable')
    if test "$version" = "$expected_openclaw_version"; then
      note "openclaw    $version"
    else
      bad "openclaw    version $version does not match the pinned $expected_openclaw_version"
    fi
    test -d "$openclaw/node_modules" || bad 'openclaw    node_modules is absent; the package must have its dependencies installed'
    test -d "$openclaw/dist" || bad 'openclaw    dist is absent'
  else
    bad "openclaw    MISSING package.json at $openclaw"
  fi

  if test -f "$wacli/go.mod"; then
    note "wacli       $wacli"
  else
    bad "wacli       MISSING go.mod at $wacli"
  fi
fi

if test "$check_only" = 'yes'; then
  note ''
  if test "$status" -eq 0; then
    note 'BOOTSTRAP_CHECK_PASS'
  else
    note 'BOOTSTRAP_CHECK_INCOMPLETE'
  fi
  exit "$status"
fi

test "$status" -eq 0 || exit "$status"

# ---- 1. NodeMobile -------------------------------------------------------

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/operator-bootstrap.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT INT TERM

staged_framework=$(resolve_framework "$nodemobile" "$work_dir/nodemobile")
is_framework "$staged_framework" || {
  printf '%s\n' 'no NodeMobile.xcframework found at that path' >&2
  exit 66
}

actual_nodemobile_sha=$(tree_sha "$staged_framework")
if test "$expected_nodemobile_sha" = 'unpinned'; then
  printf '%s\n' 'NodeMobile has no checksum on record yet, so this artifact cannot be verified.' >&2
  printf 'computed: %s\n' "$actual_nodemobile_sha" >&2
  printf '%s\n' 'Record it in bootstrap.sh (expected_nodemobile_sha) and in Runtime/DEPENDENCIES.md,' >&2
  printf '%s\n' 'then run this again. Pin it from an artifact you obtained yourself, never from a hash' >&2
  printf '%s\n' 'someone sent you - a checksum that travels with the file it describes proves nothing.' >&2
  exit 65
fi
test "$actual_nodemobile_sha" = "$expected_nodemobile_sha" || {
  printf '%s\n' 'NodeMobile checksum does not match the pin' >&2
  printf 'expected: %s\nactual:   %s\n' "$expected_nodemobile_sha" "$actual_nodemobile_sha" >&2
  exit 65
}

mkdir -p "$build_dir/native-node"
cp -R "$staged_framework" "$node_output"
printf 'nodemobile_sha256=%s\n' "$actual_nodemobile_sha" > "$build_dir/native-node/NodeMobile-info.txt"
printf '%s\n' 'BOOTSTRAP_NODEMOBILE_PASS'

# ---- 2. openclaw runtime -------------------------------------------------

node "$script_dir/native-node/package/run.mjs" "$openclaw" "$runtime_output"

# ---- 3. wacli archive ----------------------------------------------------

sh "$script_dir/native-whatsapp/archive/build.sh" "$wacli" "$whatsapp_output" simulator
sh "$script_dir/native-whatsapp/archive/build.sh" "$wacli" "$whatsapp_device_output" device

printf '%s\n' 'BOOTSTRAP_PASS'
