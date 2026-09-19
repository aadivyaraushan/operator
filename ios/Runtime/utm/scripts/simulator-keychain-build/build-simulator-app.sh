#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENTITLEMENTS="$SCRIPT_DIR/Operator-Simulator.entitlements"

usage() {
    printf 'Usage: %s /path/to/UTM-source /path/to/source-packages /path/to/output-directory\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -eq 3 ] || usage
SOURCE_ROOT=$1
SOURCE_PACKAGES=$2
OUTPUT_ROOT=$3
SYSROOT="$SOURCE_ROOT/sysroot-iOS_Simulator-TCI-arm64"

[ -f "$ENTITLEMENTS" ] || {
    printf 'error: Simulator entitlement input is missing: %s\n' "$ENTITLEMENTS" >&2
    exit 2
}
[ -f "$SOURCE_ROOT/UTM.xcodeproj/project.pbxproj" ] || {
    printf 'error: UTM project is missing: %s\n' "$SOURCE_ROOT" >&2
    exit 2
}
[ -d "$SOURCE_PACKAGES" ] || {
    printf 'error: source packages are missing: %s\n' "$SOURCE_PACKAGES" >&2
    exit 2
}
[ -d "$SYSROOT/Frameworks/vulkan.1.framework" ] || {
    printf 'error: Vulkan framework is missing from the Simulator sysroot: %s\n' "$SYSROOT" >&2
    exit 2
}

mkdir -p "$OUTPUT_ROOT/products" "$OUTPUT_ROOT/intermediates" "$OUTPUT_ROOT/precompiled" "$OUTPUT_ROOT/module-cache"
/usr/bin/xcodebuild \
    -quiet \
    -project "$SOURCE_ROOT/UTM.xcodeproj" \
    -target iOS-SE \
    -sdk iphonesimulator \
    -arch arm64 \
    -configuration Debug \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
    ONLY_ACTIVE_ARCH=YES \
    IPHONEOS_DEPLOYMENT_TARGET=18.0 \
    CLANG_MODULE_CACHE_PATH="$OUTPUT_ROOT/module-cache" \
    ASSETCATALOG_OTHER_FLAGS= \
    SYMROOT="$OUTPUT_ROOT/products" \
    OBJROOT="$OUTPUT_ROOT/intermediates" \
    SHARED_PRECOMPS_DIR="$OUTPUT_ROOT/precompiled" \
    build

APP_PATH="$OUTPUT_ROOT/products/Debug-iphonesimulator/Operator.app"
[ -d "$APP_PATH" ] || {
    printf 'error: Simulator build output did not contain Operator.app\n' >&2
    exit 1
}
/bin/mkdir -p "$APP_PATH/Frameworks"
/bin/cp -R "$SYSROOT/Frameworks/vulkan.1.framework" "$APP_PATH/Frameworks/"
"$SCRIPT_DIR/../verification/check-framework-dependencies.sh" "$APP_PATH"
# Keep Xcode's embedded Simulator entitlement section, but reseal resources added
# after the Xcode build without adding any CodeDirectory entitlements.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf 'Built Simulator-signed app: %s\n' "$APP_PATH"
