#!/bin/zsh
# Keeps a paired iPhone on the newest commit of main, the way Vercel keeps a
# site on the newest push. Run by launchd every few minutes (see install.sh)
# or by hand: `deploy.sh now` skips the "anything new?" check.
#
# One tick: fetch main -> decide (new commit? install older than 6 days?) ->
# build for the device -> install over Wi-Fi with devicectl -> record what
# is on the phone. Every step logs to $LOG; a failure also raises a Mac
# notification so a stale phone is noticed the same day.
#
# Needs, once, on this Mac: an Apple ID signed into Xcode (free personal
# team is enough), the phone paired by cable with Developer Mode on. The
# free profile expires after seven days, which is why an unchanged build is
# reinstalled on day six.
set -u
set -o pipefail

SCRIPT_DIR="${0:A:h}"
REPO="${OPERATOR_REPO:-${SCRIPT_DIR:h:h:h}}"
IOS_DIR="$REPO/ios"
STATE_DIR="${OPERATOR_AUTO_INSTALL_STATE:-$HOME/Library/Application Support/Operator/auto-install}"
STATE="$STATE_DIR/state"
LOG="${OPERATOR_AUTO_INSTALL_LOG:-$STATE_DIR/deploy.log}"
DERIVED="${OPERATOR_AUTO_INSTALL_DERIVED:-$STATE_DIR/DerivedData}"
BRANCH="${OPERATOR_AUTO_INSTALL_BRANCH:-main}"
DEVICE="${OPERATOR_DEVICE_ID:-}"
# "app.operator.ios" belongs to another Apple team, so a personal team
# cannot register it. The phone build uses a prefix made from the team id
# unless one is given. Sign-ins tied to the bundle id (Google, Microsoft)
# may refuse this build.
BUNDLE_PREFIX="${OPERATOR_BUNDLE_ID_PREFIX:-}"
REINSTALL_AFTER_SECONDS=$((6 * 24 * 60 * 60))

mkdir -p "$STATE_DIR"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [auto-install] $*" | tee -a "$LOG" >&2; }

notify() {
  # Mac notification; harmless when there is no logged-in GUI session.
  osascript -e "display notification \"$2\" with title \"Operator auto-install\" subtitle \"$1\"" >/dev/null 2>&1 || true
}

fail() {
  log "FAILED $1"
  notify "Failed" "$1"
  exit 1
}

read_state() {
  installed_sha=""; installed_at=0
  [[ -f "$STATE" ]] && source "$STATE"
}

write_state() {
  printf 'installed_sha=%s\ninstalled_at=%s\n' "$1" "$2" > "$STATE"
}

# decide <remote_sha> <installed_sha> <installed_at_epoch> <now_epoch>
# Prints one word: "new" (commit changed), "stale" (same commit but the
# free profile is about to expire), or "none". Pure so it can be tested.
decide() {
  local remote="$1" installed="$2" at="$3" now="$4"
  if [[ "$remote" != "$installed" ]]; then print new; return; fi
  if (( now - at >= REINSTALL_AFTER_SECONDS )); then print stale; return; fi
  print none
}

# The team id comes from the Apple Development certificate Xcode created
# when the Apple ID was added, so nothing has to be typed into a config.
team_id() {
  security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1
}

# The hardware id xcodebuild knows the phone by. Building for the phone
# itself, not for "any iPhone", is what lets Xcode register it with the team
# the first time; without a registered device Apple issues no profile.
device_udid() {
  if [[ -n "$DEVICE" ]]; then print -r -- "$DEVICE"; return; fi
  xcrun devicectl list devices --json-output - 2>/dev/null \
    | sed -n 's/.*"udid" *: *"\([0-9A-F]\{8\}-[0-9A-F]\{16\}\)".*/\1/p' | head -1
}

run_tick() {
  local force="$1"
  read_state
  log "tick branch=$BRANCH installed=${installed_sha:-none} force=$force"

  git -C "$REPO" fetch -q origin "$BRANCH" || fail "git fetch origin $BRANCH"
  local remote_sha; remote_sha=$(git -C "$REPO" rev-parse "origin/$BRANCH") || fail "rev-parse origin/$BRANCH"

  local action; action=$(decide "$remote_sha" "$installed_sha" "$installed_at" "$(date +%s)")
  [[ "$force" == 1 ]] && action=forced
  log "decision=$action remote=$remote_sha"
  [[ "$action" == none ]] && return 0

  local team; team=$(team_id)
  [[ -n "$team" ]] || fail "no Apple Development certificate: sign into Xcode > Settings > Accounts first"
  local dev; dev=$(device_udid)
  [[ -n "$dev" ]] || fail "no paired iPhone: plug it in once and tap Trust"

  # Build from a clean checkout of the exact commit, never from the working
  # tree, so what lands on the phone is what is on GitHub.
  local src="$STATE_DIR/checkout"
  if [[ -d "$src/.git" ]]; then
    git -C "$src" fetch -q origin "$BRANCH" && git -C "$src" checkout -q --detach "$remote_sha" || fail "checkout $remote_sha"
  else
    git clone -q --no-checkout "$(git -C "$REPO" remote get-url origin)" "$src" && git -C "$src" checkout -q --detach "$remote_sha" || fail "clone for $remote_sha"
  fi

  # The Node runtime is staged per machine and ignored by git; the clean
  # checkout borrows this repo's staged copy. The build's own check fails
  # if that copy is older than the commit being built.
  if [[ ! -e "$src/ios/build" ]]; then
    [[ -d "$IOS_DIR/build/native-node" ]] || fail "no staged runtime at $IOS_DIR/build (run ios/Runtime/bootstrap.sh once)"
    ln -s "$IOS_DIR/build" "$src/ios/build" || fail "link staged runtime"
  fi

  local destination="platform=iOS,id=$dev"
  local prefix="${BUNDLE_PREFIX:-app.operator.${team:l}}"
  local bundle_id="$prefix.ios"
  log "building $remote_sha team=$team bundle=$bundle_id"
  xcodebuild -quiet -project "$src/ios/Operator.xcodeproj" -scheme OperatorApp \
    -destination "$destination" -configuration Debug \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic OPERATOR_BUNDLE_ID_PREFIX="$prefix" \
    build >>"$LOG" 2>&1 || fail "xcodebuild for $remote_sha (see $LOG)"

  local app="$DERIVED/Build/Products/Debug-iphoneos/Operator.app"
  [[ -d "$app" ]] || fail "built app missing at $app"

  log "installing on device=$dev"
  xcrun devicectl device install app --device "$dev" "$app" >>"$LOG" 2>&1 || fail "install on $dev (is the phone on this Wi-Fi and unlocked?)"
  xcrun devicectl device process launch --device "$dev" --terminate-existing "$bundle_id" >>"$LOG" 2>&1 || log "launch failed; the app is installed but not opened"

  write_state "$remote_sha" "$(date +%s)"
  log "installed $remote_sha"
  notify "Installed" "$(git -C "$src" log -1 --format=%s "$remote_sha")"
}

case "${1:-tick}" in
  tick)   run_tick 0 ;;
  now)    run_tick 1 ;;
  decide) decide "$2" "$3" "$4" "$5" ;;
  status)
    read_state
    print "installed: ${installed_sha:-none}"
    [[ "$installed_at" != 0 ]] && print "installed at: $(date -r "$installed_at" '+%Y-%m-%d %H:%M')"
    print "log: $LOG"
    ;;
  *) print "usage: deploy.sh [tick|now|status]" >&2; exit 2 ;;
esac
