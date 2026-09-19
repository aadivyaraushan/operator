#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UTM_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$UTM_DIR/../../.." && pwd)
# shellcheck disable=SC1091
. "$UTM_DIR/manifest.env"

usage() {
    printf 'Usage: %s /path/to/UTM-source /path/to/sysroot-iOS-TCI-arm64 /path/to/source-packages /path/to/output-directory /path/to/Operator.utm\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -eq 5 ] || usage
SOURCE_ROOT=$1
SYSROOT=$2
SOURCE_PACKAGES=$3
OUTPUT_ROOT=$4
GUEST_BUNDLE=$5

[ -d "$SYSROOT/Frameworks" ] || {
    printf 'error: sysroot Frameworks directory is missing: %s\n' "$SYSROOT/Frameworks" >&2
    exit 2
}
[ -d "$SYSROOT/include" ] || {
    printf 'error: sysroot include directory is missing: %s\n' "$SYSROOT/include" >&2
    exit 2
}
[ -d "$SYSROOT/lib" ] || {
    printf 'error: sysroot lib directory is missing: %s\n' "$SYSROOT/lib" >&2
    exit 2
}
[ -d "$GUEST_BUNDLE" ] || {
    printf 'error: Operator UTM bundle is missing: %s\n' "$GUEST_BUNDLE" >&2
    exit 2
}
[ -f "$GUEST_BUNDLE/config.plist" ] || {
    printf 'error: Operator UTM bundle config.plist is missing: %s\n' "$GUEST_BUNDLE" >&2
    exit 2
}
[ -f "$GUEST_BUNDLE/Data/operator.qcow2" ] || {
    printf 'error: Operator UTM bundle disk image is missing: %s\n' "$GUEST_BUNDLE" >&2
    exit 2
}
"$SCRIPT_DIR/apply-overlay.sh" "$SOURCE_ROOT"
"$SCRIPT_DIR/apply-utm-restore-result.sh" "$SOURCE_ROOT"
"$SCRIPT_DIR/apply-qemukit-snapshot-timeout.sh" "$SOURCE_PACKAGES"

expected_sysroot="$SOURCE_ROOT/sysroot-iOS-TCI-arm64"
if [ -e "$expected_sysroot" ] || [ -L "$expected_sysroot" ]; then
    [ "$(cd "$expected_sysroot" && pwd -P)" = "$(cd "$SYSROOT" && pwd -P)" ] || {
        printf 'error: %s already points at a different sysroot\n' "$expected_sysroot" >&2
        exit 2
    }
else
    ln -s "$SYSROOT" "$expected_sysroot"
fi

mkdir -p "$OUTPUT_ROOT/products" "$OUTPUT_ROOT/intermediates" "$OUTPUT_ROOT/precompiled" "$OUTPUT_ROOT/module-cache"
/usr/bin/xcodebuild \
    -quiet \
    -project "$SOURCE_ROOT/UTM.xcodeproj" \
    -target "$UTM_SCHEME" \
    -sdk "$UTM_SDK" \
    -arch "$UTM_ARCH" \
    -configuration Debug \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    IPHONEOS_DEPLOYMENT_TARGET=18.0 \
    CLANG_MODULE_CACHE_PATH="$OUTPUT_ROOT/module-cache" \
    ASSETCATALOG_OTHER_FLAGS= \
    SYMROOT="$OUTPUT_ROOT/products" \
    OBJROOT="$OUTPUT_ROOT/intermediates" \
    SHARED_PRECOMPS_DIR="$OUTPUT_ROOT/precompiled" \
    build

APP_PATH=$(find "$OUTPUT_ROOT/products" -type d -name 'Operator.app' -print | head -1)
[ -n "$APP_PATH" ] || {
    printf 'error: build output did not contain Operator.app\n' >&2
    exit 2
}
APP_BINARY="$APP_PATH/Operator"
[ -f "$APP_BINARY" ] || {
    printf 'error: app binary is missing: %s\n' "$APP_BINARY" >&2
    exit 2
}
/usr/bin/file "$APP_BINARY" | grep -F 'arm64' >/dev/null || {
    printf 'error: app binary is not arm64\n' >&2
    exit 2
}

# Extension versions follow the actual containing app, including UTM builds.
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Info.plist")
APP_BUILD=$(plutil -extract CFBundleVersion raw -o - "$APP_PATH/Info.plist")
WIDGET_BUILD_ROOT="$OUTPUT_ROOT/widget-build"
/usr/bin/xcodebuild \
    -quiet \
    -project "$PROJECT_ROOT/ios/Operator.xcodeproj" \
    -target OperatorWidget \
    -sdk iphoneos \
    -arch arm64 \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    IPHONEOS_DEPLOYMENT_TARGET=18.0 \
    MARKETING_VERSION="$APP_VERSION" \
    CURRENT_PROJECT_VERSION="$APP_BUILD" \
    SYMROOT="$WIDGET_BUILD_ROOT/products" \
    OBJROOT="$WIDGET_BUILD_ROOT/intermediates" \
    build
WIDGET_PATH="$WIDGET_BUILD_ROOT/products/Debug-iphoneos/OperatorWidget.appex"
[ -d "$WIDGET_PATH" ] || {
    printf 'error: widget build output is missing: %s\n' "$WIDGET_PATH" >&2
    exit 2
}
"$PROJECT_ROOT/ios/OperatorWidgetTests/operator_widget_contract_test.sh" "$WIDGET_PATH" "$APP_PATH"

cp -R "$GUEST_BUNDLE" "$APP_PATH/Operator.utm"
mkdir -p "$APP_PATH/PlugIns"
cp -R "$WIDGET_PATH" "$APP_PATH/PlugIns/OperatorWidget.appex"
# virglrenderer links Vulkan even though the app does not link it directly.
cp -R "$SYSROOT/Frameworks/vulkan.1.framework" "$APP_PATH/Frameworks/"
"$SCRIPT_DIR/verification/check-framework-dependencies.sh" "$APP_PATH"
printf 'Built unsigned arm64 app: %s\n' "$APP_PATH"
