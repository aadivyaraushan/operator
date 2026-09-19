#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECKER="$SCRIPT_DIR/../../scripts/verification/check-framework-dependencies.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/operator-framework-dependencies.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
APP="$TEMP_ROOT/Operator.app"
MOCK_BIN="$TEMP_ROOT/mock-bin"
mkdir -p "$APP/Frameworks/virglrenderer.framework" "$MOCK_BIN"
touch "$APP/Operator" "$APP/Frameworks/virglrenderer.framework/virglrenderer"
chmod +x "$APP/Operator" "$APP/Frameworks/virglrenderer.framework/virglrenderer"

cat >"$MOCK_BIN/otool" <<'EOF'
#!/bin/sh
case "$2" in
  */Operator)
    printf '%s:\n\t@rpath/virglrenderer.framework/virglrenderer (compatibility version 1.0.0, current version 1.0.0)\n' "$2"
    ;;
  */virglrenderer.framework/virglrenderer)
    printf '%s:\n\t@rpath/vulkan.1.framework/vulkan.1 (compatibility version 1.0.0, current version 1.0.0)\n' "$2"
    ;;
  *)
    printf '%s:\n' "$2"
    ;;
esac
EOF
chmod +x "$MOCK_BIN/otool"

cat >"$MOCK_BIN/file" <<'EOF'
#!/bin/sh
printf 'Mach-O 64-bit dynamically linked shared library arm64\n'
EOF
chmod +x "$MOCK_BIN/file"

if OTOOL="$MOCK_BIN/otool" FILE="$MOCK_BIN/file" "$CHECKER" "$APP" >"$TEMP_ROOT/missing.out" 2>&1; then
    fail 'missing transitive framework unexpectedly passed'
fi
grep -F "ERROR: missing embedded framework: @rpath/vulkan.1.framework/vulkan.1 required by $APP/Frameworks/virglrenderer.framework/virglrenderer" "$TEMP_ROOT/missing.out" >/dev/null || fail 'missing framework error did not identify the indirect dependency'

mkdir -p "$APP/Frameworks/vulkan.1.framework"
touch "$APP/Frameworks/vulkan.1.framework/vulkan.1"
chmod +x "$APP/Frameworks/vulkan.1.framework/vulkan.1"
OTOOL="$MOCK_BIN/otool" FILE="$MOCK_BIN/file" "$CHECKER" "$APP" >"$TEMP_ROOT/present.out" 2>&1 || fail 'present framework dependency failed'
grep -F 'PASS: embedded @rpath framework dependencies' "$TEMP_ROOT/present.out" >/dev/null || fail 'present framework did not report pass'

cat >"$MOCK_BIN/otool-fails" <<'EOF'
#!/bin/sh
printf 'intentional otool failure\n' >&2
exit 7
EOF
chmod +x "$MOCK_BIN/otool-fails"
if OTOOL="$MOCK_BIN/otool-fails" FILE="$MOCK_BIN/file" "$CHECKER" "$APP" >"$TEMP_ROOT/tool-failure.out" 2>&1; then
    fail 'otool failure unexpectedly passed'
fi
grep -F "ERROR: otool failed for $APP/Operator (exit 7): intentional otool failure" "$TEMP_ROOT/tool-failure.out" >/dev/null || fail 'otool failure was not reported precisely'

mkdir -p "$APP/Operator.utm"
CONFIG="$APP/Operator.utm/config.plist"
cat >"$CONFIG" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>System</key><dict><key>Architecture</key><string>aarch64</string></dict></dict></plist>
EOF
if OTOOL="$MOCK_BIN/otool" FILE="$MOCK_BIN/file" "$CHECKER" "$APP" >"$TEMP_ROOT/missing-engine.out" 2>&1; then
    fail 'missing configuration-selected emulator unexpectedly passed'
fi
grep -F 'ERROR: missing guest emulator: qemu-aarch64-softmmu' "$TEMP_ROOT/missing-engine.out" >/dev/null || fail 'missing emulator error did not identify the selected architecture'

for architecture in aarch64 x86_64; do
    plutil -replace System.Architecture -string "$architecture" "$CONFIG"
    mkdir -p "$APP/Frameworks/qemu-$architecture-softmmu.framework"
    touch "$APP/Frameworks/qemu-$architecture-softmmu.framework/qemu-$architecture-softmmu"
    OTOOL="$MOCK_BIN/otool" FILE="$MOCK_BIN/file" "$CHECKER" "$APP" >"$TEMP_ROOT/engine-present.out" 2>&1 || fail "present $architecture emulator failed"
    grep -F "PASS: guest emulator: qemu-$architecture-softmmu" "$TEMP_ROOT/engine-present.out" >/dev/null || fail 'selected emulator was not reported'
done

plutil -replace System.Architecture -string '../aarch64' "$CONFIG"
if OTOOL="$MOCK_BIN/otool" FILE="$MOCK_BIN/file" "$CHECKER" "$APP" >"$TEMP_ROOT/invalid-architecture.out" 2>&1; then
    fail 'invalid architecture unexpectedly passed'
fi
grep -F 'ERROR: invalid guest architecture' "$TEMP_ROOT/invalid-architecture.out" >/dev/null || fail 'invalid architecture error missing'

plutil -remove System.Architecture "$CONFIG"
if OTOOL="$MOCK_BIN/otool" FILE="$MOCK_BIN/file" "$CHECKER" "$APP" >"$TEMP_ROOT/missing-architecture.out" 2>&1; then
    fail 'missing architecture unexpectedly passed'
fi
grep -F 'ERROR: cannot read guest architecture' "$TEMP_ROOT/missing-architecture.out" >/dev/null || fail 'missing architecture error missing'

printf 'PASS: framework dependency checker\n'
