#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UTM_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_SCRIPT="$UTM_DIR/scripts/build-operator-utm.sh"
UNSIGNED_BUILD_SCRIPT="$UTM_DIR/scripts/build-unsigned.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_value() {
    actual=$1
    expected=$2
    label=$3
    [ "$actual" = "$expected" ] || fail "$label: expected '$expected', found '$actual'"
}

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/operator-utm-bundle.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

QCOW2="$TEMP_ROOT/production.qcow2"
OUTPUT="$TEMP_ROOT/Operator.utm"
SECOND_OUTPUT="$TEMP_ROOT/Operator-second.utm"
dd if=/dev/zero of="$QCOW2" bs=1 count=1 2>/dev/null

[ -x "$BUILD_SCRIPT" ] || fail "build-operator-utm.sh is missing or not executable"
[ -x "$UNSIGNED_BUILD_SCRIPT" ] || fail "build-unsigned.sh is missing or not executable"
grep -F -- 'Usage: %s /path/to/UTM-source /path/to/sysroot-iOS-TCI-arm64 /path/to/source-packages /path/to/output-directory /path/to/Operator.utm' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not require Operator.utm"
grep -F -- 'GUEST_BUNDLE=$5' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not accept the Operator.utm bundle"
grep -F -- '[ -f "$GUEST_BUNDLE/config.plist" ]' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not require config.plist"
grep -F -- '[ -f "$GUEST_BUNDLE/Data/operator.qcow2" ]' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not require Data/operator.qcow2"
grep -F -- 'cp -R "$GUEST_BUNDLE" "$APP_PATH/Operator.utm"' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not embed Operator.utm in Operator.app"
grep -F -- 'OperatorWidget.appex' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not embed OperatorWidget.appex in Operator.app"
grep -F -- 'PlugIns' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not create the app extension directory"
grep -F -- '"$SCRIPT_DIR/verification/check-framework-dependencies.sh" "$APP_PATH"' "$UNSIGNED_BUILD_SCRIPT" >/dev/null || fail "build-unsigned.sh does not verify embedded frameworks"
"$BUILD_SCRIPT" "$QCOW2" "$OUTPUT" >"$TEMP_ROOT/build.out"
[ -d "$OUTPUT" ] || fail "Operator.utm bundle missing"
[ -f "$OUTPUT/config.plist" ] || fail "config.plist missing"
[ -f "$OUTPUT/Data/operator.qcow2" ] || fail "Data/operator.qcow2 missing"
cmp -s "$QCOW2" "$OUTPUT/Data/operator.qcow2" || fail "qcow2 contents changed"
"$BUILD_SCRIPT" "$QCOW2" "$SECOND_OUTPUT" >/dev/null
cmp -s "$OUTPUT/config.plist" "$SECOND_OUTPUT/config.plist" || fail "same input did not produce deterministic config"

extract() { plutil -extract "$1" raw -o - "$OUTPUT/config.plist"; }
assert_empty_array() {
    array_xml=$(plutil -extract "$1" xml1 -o - "$OUTPUT/config.plist")
    printf '%s\n' "$array_xml" | grep -Eq '<array[[:space:]]*/>' || fail "$1 is not empty"
}
assert_value "$(extract Information.Name)" "Operator" "name"
assert_value "$(extract Information.IconCustom)" "false" "custom icon"
assert_value "$(extract System.Architecture)" "x86_64" "architecture"
assert_value "$(extract System.Target)" "q35" "target"
assert_value "$(extract System.CPU)" "default" "CPU"
assert_empty_array System.CPUFlagsAdd
assert_empty_array System.CPUFlagsRemove
assert_value "$(extract System.CPUCount)" "0" "CPU count"
assert_value "$(extract System.ForceMulticore)" "false" "force multicore"
assert_value "$(extract System.MemorySize)" "1024" "memory"
assert_value "$(extract System.JITCacheSize)" "0" "JIT cache"
assert_empty_array QEMU.AdditionalArguments
assert_empty_array Display
assert_value "$(extract QEMU.DebugLog)" "false" "debug log"
assert_value "$(extract QEMU.UEFIBoot)" "false" "UEFI boot"
assert_value "$(extract QEMU.RNGDevice)" "false" "RNG device"
assert_value "$(extract QEMU.BalloonDevice)" "false" "balloon device"
assert_value "$(extract QEMU.TPMDevice)" "false" "TPM device"
assert_value "$(extract QEMU.Hypervisor)" "false" "hypervisor"
assert_value "$(extract QEMU.RTCLocalTime)" "false" "RTC local time"
assert_value "$(extract QEMU.PS2Controller)" "false" "PS2 controller"
assert_value "$(extract Input.UsbBusSupport)" "3.0" "USB"
assert_value "$(extract Input.UsbSharing)" "false" "USB sharing"
assert_value "$(extract Input.MaximumUsbShare)" "3" "USB maximum"
assert_value "$(extract Sharing.DirectoryShareMode)" "None" "directory sharing"
assert_value "$(extract Sharing.DirectoryShareReadOnly)" "false" "directory read-only"
assert_value "$(extract Sharing.ClipboardSharing)" "false" "clipboard sharing"
assert_empty_array Serial
assert_empty_array Sound
assert_value "$(extract Drive.0.ImageName)" "operator.qcow2" "drive image"
assert_value "$(extract Drive.0.Interface)" "IDE" "drive interface"
assert_value "$(extract Drive.0.InterfaceVersion)" "1" "drive interface version"
assert_value "$(extract Network.0.Mode)" "Emulated" "network mode"
assert_value "$(extract Network.0.Hardware)" "e1000" "network hardware"
mac=$(extract Network.0.MacAddress)
printf '%s\n' "$mac" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' || fail "invalid MAC address: $mac"
first_octet=$(printf '%s' "$mac" | cut -d: -f1)
first_decimal=$(printf '%d' "0x$first_octet")
[ $((first_decimal & 2)) -ne 0 ] || fail "MAC is not locally administered: $mac"
assert_value "$(extract Network.0.IsolateFromHost)" "false" "network isolation"
assert_value "$(extract Network.0.PortForward.0.Protocol)" "TCP" "forward protocol"
assert_value "$(extract Network.0.PortForward.0.HostAddress)" "127.0.0.1" "forward host"
assert_value "$(extract Network.0.PortForward.0.HostPort)" "18789" "forward host port"
assert_value "$(extract Network.0.PortForward.0.GuestPort)" "18789" "forward guest port"
assert_value "$(extract Backend)" "QEMU" "backend"
assert_value "$(extract ConfigurationVersion)" "4" "configuration version"

printf 'PASS: operator UTM bundle contract\n'
