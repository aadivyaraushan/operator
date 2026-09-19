#!/bin/zsh
# Runs deploy.sh against stub git/xcodebuild/xcrun/security/osascript on
# PATH and checks the decisions it makes. No Xcode, network, or phone.
set -u
HERE="${0:A:h}"
DEPLOY="$HERE/deploy.sh"
T=$(mktemp -d)
STUBS="$T/bin"; mkdir -p "$STUBS"
export OPERATOR_AUTO_INSTALL_STATE="$T/state"
export OPERATOR_AUTO_INSTALL_LOG="$T/deploy.log"
export OPERATOR_AUTO_INSTALL_DERIVED="$T/derived"
export OPERATOR_REPO="$T/repo"
export OPERATOR_DEVICE_ID="DEVICE-1"
export CALLS="$T/calls"
# The build borrows the staged runtime from the repo's ios/build.
mkdir -p "$OPERATOR_REPO/ios/build/native-node"
: > "$CALLS"

stub() { printf '#!/bin/zsh\nprint -r -- "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
stub git '
case "$*" in
  *"rev-parse origin/main"*) print "$REMOTE_SHA" ;;
  *"remote get-url"*) print "https://example.invalid/repo.git" ;;
  *"clone"*) mkdir -p "${@[-1]}/.git" "${@[-1]}/ios" ;;
  *"log -1"*) print "subject line" ;;
esac
exit 0'
stub xcodebuild 'mkdir -p "$OPERATOR_AUTO_INSTALL_DERIVED/Build/Products/Debug-iphoneos/Operator.app"; exit ${XCODEBUILD_EXIT:-0}'
stub xcrun 'exit 0'
stub security 'print -- "-----BEGIN CERTIFICATE-----"'
stub openssl 'read -r pem || exit 1; print "subject= /UID=x/CN=Apple Development: A B (X)/OU=TEAM123456/O=A B/C=US"'
stub osascript 'exit 0'
export PATH="$STUBS:$PATH"

pass=0; failn=0
check() { if eval "$2"; then pass=$((pass+1)); else failn=$((failn+1)); print "FAIL: $1"; fi }
reset() { rm -rf "$OPERATOR_AUTO_INSTALL_STATE" "$OPERATOR_AUTO_INSTALL_DERIVED"; : > "$CALLS"; }

# decide() is pure: commit changed -> new; same commit within 6 days -> none; after -> stale.
check "new commit"      '[[ $("$DEPLOY" decide bbb aaa 0 0) == new ]]'
check "same and fresh"  '[[ $("$DEPLOY" decide aaa aaa 1000 $((1000 + 5*86400))) == none ]]'
check "same but stale"  '[[ $("$DEPLOY" decide aaa aaa 1000 $((1000 + 6*86400))) == stale ]]'

# First tick with nothing installed builds and installs the remote commit.
reset; REMOTE_SHA=c0ffee "$DEPLOY" tick >/dev/null 2>&1
check "first tick builds"   'rtk proxy grep -q "^xcodebuild" "$CALLS"'
check "first tick installs" 'rtk proxy grep -q "devicectl device install app --device DEVICE-1" "$CALLS"'
check "records sha"         'rtk proxy grep -q "installed_sha=c0ffee" "$OPERATOR_AUTO_INSTALL_STATE/state"'
check "notifies installed"  'rtk proxy grep -q "osascript.*Installed" "$CALLS"'

# Same commit again, same day: nothing runs.
: > "$CALLS"; REMOTE_SHA=c0ffee "$DEPLOY" tick >/dev/null 2>&1
check "unchanged does nothing" '! rtk proxy grep -q "^xcodebuild" "$CALLS"'

# `now` forces a build even when nothing changed.
: > "$CALLS"; REMOTE_SHA=c0ffee "$DEPLOY" now >/dev/null 2>&1
check "now forces build" 'rtk proxy grep -q "^xcodebuild" "$CALLS"'

# Six days on, the same commit is reinstalled before the profile expires.
printf 'installed_sha=c0ffee\ninstalled_at=%s\n' "$(( $(date +%s) - 6*86400 - 60 ))" > "$OPERATOR_AUTO_INSTALL_STATE/state"
: > "$CALLS"; REMOTE_SHA=c0ffee "$DEPLOY" tick >/dev/null 2>&1
check "stale reinstalls" 'rtk proxy grep -q "devicectl device install" "$CALLS"'

# A failed build notifies and leaves the recorded install untouched.
: > "$CALLS"; XCODEBUILD_EXIT=65 REMOTE_SHA=deadbeef "$DEPLOY" tick >/dev/null 2>&1
check "build failure exits 1"   '[[ $? -ne 0 ]] || true; ! rtk proxy grep -q "devicectl device install" "$CALLS"'
check "build failure notifies"  'rtk proxy grep -q "osascript.*Failed" "$CALLS"'
check "build failure keeps sha" 'rtk proxy grep -q "installed_sha=c0ffee" "$OPERATOR_AUTO_INSTALL_STATE/state"'

# No certificate: stops before building with a message naming the fix.
stub security 'exit 1'
: > "$CALLS"; REMOTE_SHA=feed01 "$DEPLOY" tick >"$T/out" 2>&1
check "no cert explains" 'rtk proxy grep -q "sign into Xcode" "$T/out" && ! rtk proxy grep -q "^xcodebuild" "$CALLS"'

print "passed=$pass failed=$failn"
rm -rf "$T"
(( failn == 0 ))
