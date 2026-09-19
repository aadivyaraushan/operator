#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
utm_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd)
builder="$utm_dir/scripts/simulator-keychain-build/build-simulator-app.sh"
entitlements="$utm_dir/scripts/simulator-keychain-build/Operator-Simulator.entitlements"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

test -x "$builder" || fail "Simulator Xcode builder is missing"
test -f "$entitlements" || fail "Simulator entitlement input is missing"

grep -F -- '-sdk iphonesimulator' "$builder" >/dev/null || fail "builder does not target the Simulator SDK"
grep -F -- 'CODE_SIGNING_ALLOWED=YES' "$builder" >/dev/null || fail "builder does not let Xcode sign the Simulator app"
grep -F -- 'CODE_SIGN_IDENTITY=-' "$builder" >/dev/null || fail "builder does not use Simulator ad-hoc identity"
grep -F -- 'CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS"' "$builder" >/dev/null || fail "builder does not pass the Simulator entitlement input to Xcode"
if grep -F -- 'codesign --force' "$builder" | grep -F -- '--entitlements' >/dev/null; then
  fail "builder must not add restricted entitlements with a post-build codesign command"
fi
grep -F -- 'vulkan.1.framework' "$builder" >/dev/null || fail "builder does not include the required Vulkan framework"
grep -F -- 'check-framework-dependencies.sh' "$builder" >/dev/null || fail "builder does not check packaged framework dependencies"
grep -F -- 'sysroot-iOS_Simulator-TCI-arm64' "$builder" >/dev/null || fail "builder does not use the Simulator sysroot"
if grep -F -- 'sysroot-iOS-TCI-arm64' "$builder" >/dev/null; then
  fail "builder still uses the device sysroot path"
fi
grep -F -- '$(CFBundleIdentifier)' "$entitlements" >/dev/null || fail "entitlement input does not derive identity from the bundle ID"
grep -F -- '<key>application-identifier</key>' "$entitlements" >/dev/null || fail "entitlement input lacks application identifier"
grep -F -- '<key>keychain-access-groups</key>' "$entitlements" >/dev/null || fail "entitlement input lacks keychain groups"

printf 'PASS: Simulator Xcode keychain-signing contract\n'
