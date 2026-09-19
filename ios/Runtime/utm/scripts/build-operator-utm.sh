#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s /path/to/production.qcow2 [output/Operator.utm]\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
QCOW2_PATH=$1
OUTPUT_PATH=${2:-Operator.utm}

[ -f "$QCOW2_PATH" ] || { printf 'error: qcow2 image does not exist: %s\n' "$QCOW2_PATH" >&2; exit 1; }
[ ! -e "$OUTPUT_PATH" ] || { printf 'error: output already exists: %s\n' "$OUTPUT_PATH" >&2; exit 1; }

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/operator-utm-build.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

PACKAGE="$TEMP_ROOT/Operator.utm"
mkdir -p "$PACKAGE/Data"
cp "$QCOW2_PATH" "$PACKAGE/Data/operator.qcow2"

cat >"$PACKAGE/config.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Information</key><dict><key>Name</key><string>Operator</string><key>IconCustom</key><false/><key>UUID</key><string>00000000-0000-4000-8000-000000000001</string></dict>
<key>System</key><dict><key>Architecture</key><string>x86_64</string><key>Target</key><string>q35</string><key>CPU</key><string>default</string><key>CPUFlagsAdd</key><array/><key>CPUFlagsRemove</key><array/><key>CPUCount</key><integer>0</integer><key>ForceMulticore</key><false/><key>MemorySize</key><integer>1024</integer><key>JITCacheSize</key><integer>0</integer></dict>
<key>QEMU</key><dict><key>DebugLog</key><false/><key>UEFIBoot</key><false/><key>RNGDevice</key><false/><key>BalloonDevice</key><false/><key>TPMDevice</key><false/><key>Hypervisor</key><false/><key>TSO</key><false/><key>RTCLocalTime</key><false/><key>PS2Controller</key><false/><key>AdditionalArguments</key><array/></dict>
<key>Input</key><dict><key>UsbBusSupport</key><string>3.0</string><key>UsbSharing</key><false/><key>MaximumUsbShare</key><integer>3</integer></dict>
<key>Sharing</key><dict><key>DirectoryShareMode</key><string>None</string><key>DirectoryShareReadOnly</key><false/><key>ClipboardSharing</key><false/></dict>
<key>Display</key><array/><key>Drive</key><array><dict><key>ImageName</key><string>operator.qcow2</string><key>ReadOnly</key><false/><key>ImageType</key><string>Disk</string><key>Interface</key><string>IDE</string><key>InterfaceVersion</key><integer>1</integer><key>Identifier</key><string>00000000-0000-4000-8000-000000000002</string></dict></array>
<key>Network</key><array><dict><key>Mode</key><string>Emulated</string><key>Hardware</key><string>e1000</string><key>MacAddress</key><string>02:00:00:00:00:01</string><key>IsolateFromHost</key><false/><key>PortForward</key><array><dict><key>Protocol</key><string>TCP</string><key>HostAddress</key><string>127.0.0.1</string><key>HostPort</key><integer>18789</integer><key>GuestPort</key><integer>18789</integer></dict></array></dict></array>
<key>Serial</key><array/><key>Sound</key><array/><key>Backend</key><string>QEMU</string><key>ConfigurationVersion</key><integer>4</integer>
</dict></plist>
PLIST

plutil -convert binary1 "$PACKAGE/config.plist"
mv "$PACKAGE" "$OUTPUT_PATH"
printf 'Created Operator UTM bundle: %s\n' "$OUTPUT_PATH"
