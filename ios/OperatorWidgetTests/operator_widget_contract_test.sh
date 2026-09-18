#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_SPEC="$IOS_DIR/project.yml"
WIDGET_SOURCE="$IOS_DIR/OperatorWidget/Sources/OperatorWidget.swift"
WIDGET_INFO_PLIST="$IOS_DIR/OperatorWidget/Info.plist"
WIDGET_PRODUCT=${1:-"$IOS_DIR/build/Debug-iphoneos/OperatorWidget.appex"}
PARENT_PRODUCT=${2:-}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    file=$1
    text=$2
    grep -F -- "$text" "$file" >/dev/null || fail "$file is missing: $text"
}

assert_value() {
    actual=$1
    expected=$2
    label=$3
    [ "$actual" = "$expected" ] || fail "$label: expected '$expected', found '$actual'"
}

[ -f "$WIDGET_SOURCE" ] || fail "Operator widget source does not exist"
[ -f "$WIDGET_INFO_PLIST" ] || fail "Operator widget Info.plist does not exist"
assert_contains "$PROJECT_SPEC" 'OperatorWidget:'
assert_contains "$PROJECT_SPEC" 'type: app-extension'
assert_contains "$PROJECT_SPEC" 'PRODUCT_BUNDLE_IDENTIFIER: $(OPERATOR_BUNDLE_ID_PREFIX).ios.widget'
assert_contains "$PROJECT_SPEC" 'target: OperatorWidget'
assert_contains "$PROJECT_SPEC" 'embed: true'
assert_contains "$WIDGET_SOURCE" 'StaticConfiguration'
assert_contains "$WIDGET_SOURCE" '.systemSmall'
assert_contains "$WIDGET_SOURCE" '.accessoryCircular'
assert_contains "$WIDGET_SOURCE" '.accessoryRectangular'
assert_contains "$WIDGET_SOURCE" 'Text("Open Operator")'
assert_contains "$WIDGET_SOURCE" 'ControlWidgetButton(action: OpenOperatorIntent())'
assert_contains "$WIDGET_SOURCE" 'static let openAppWhenRun = true'
assert_contains "$WIDGET_SOURCE" 'OpenOperatorControl()'
assert_contains "$WIDGET_INFO_PLIST" '<key>NSExtensionPointIdentifier</key>'
assert_contains "$WIDGET_INFO_PLIST" '<string>com.apple.widgetkit-extension</string>'
if grep -E 'widgetURL|Link\(' "$WIDGET_SOURCE" >/dev/null; then
    fail "widget must use the containing app's default tap behavior"
fi
if grep -E 'ChatSession|Conversation|URLSession|Task\(' "$WIDGET_SOURCE" >/dev/null; then
    fail "widget must not expose private data or perform work"
fi

[ -d "$WIDGET_PRODUCT" ] || fail "built widget product does not exist: $WIDGET_PRODUCT"
[ -f "$WIDGET_PRODUCT/Info.plist" ] || fail "built widget Info.plist does not exist"
assert_value "$(plutil -extract CFBundleIdentifier raw -o - "$WIDGET_PRODUCT/Info.plist")" "app.operator.ios.widget" "widget bundle identifier"
assert_value "$(plutil -extract CFBundleExecutable raw -o - "$WIDGET_PRODUCT/Info.plist")" "OperatorWidget" "widget executable"
assert_value "$(plutil -extract CFBundlePackageType raw -o - "$WIDGET_PRODUCT/Info.plist")" "XPC!" "widget package type"
test -n "$(plutil -extract CFBundleShortVersionString raw -o - "$WIDGET_PRODUCT/Info.plist")" || fail "widget short version is missing"
test -n "$(plutil -extract CFBundleVersion raw -o - "$WIDGET_PRODUCT/Info.plist")" || fail "widget build version is missing"
test -f "$WIDGET_PRODUCT/OperatorWidget" || fail "widget executable is missing"
if [ -n "$PARENT_PRODUCT" ]; then
    [ -f "$PARENT_PRODUCT/Info.plist" ] || fail "parent app Info.plist does not exist"
    assert_value "$(plutil -extract CFBundleShortVersionString raw -o - "$WIDGET_PRODUCT/Info.plist")" "$(plutil -extract CFBundleShortVersionString raw -o - "$PARENT_PRODUCT/Info.plist")" "widget short version must match parent app"
    assert_value "$(plutil -extract CFBundleVersion raw -o - "$WIDGET_PRODUCT/Info.plist")" "$(plutil -extract CFBundleVersion raw -o - "$PARENT_PRODUCT/Info.plist")" "widget build version must match parent app"
fi

printf 'PASS: Operator widget contract\n'
