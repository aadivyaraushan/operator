#!/bin/zsh
# Registers deploy.sh with launchd so it runs every five minutes while this
# Mac is awake, then runs it once right away. Run again to reinstall after
# editing; `install.sh remove` unloads it.
set -eu
SCRIPT_DIR="${0:A:h}"
LABEL="app.operator.auto-install"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/Library/Application Support/Operator/auto-install"
# The branch the job follows is fixed when it is registered.
BRANCH="${OPERATOR_AUTO_INSTALL_BRANCH:-main}"

if [[ "${1:-}" == remove ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  print "removed $LABEL"
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR"

# macOS does not let a background job read ~/Documents, Desktop or Downloads,
# and a repo often lives there. So the job gets its own copies outside the
# repo: the script, the repo's address, and the staged runtime (an APFS clone,
# which takes no extra disk space). Run install.sh again after editing
# deploy.sh or re-staging the runtime.
IOS_DIR="${SCRIPT_DIR:h:h}"
[[ -d "$IOS_DIR/build/native-node" ]] || { print "no staged runtime at $IOS_DIR/build (run ios/Runtime/bootstrap.sh once)" >&2; exit 1; }
ORIGIN_URL=$(git -C "$IOS_DIR" remote get-url origin)
cp "$SCRIPT_DIR/deploy.sh" "$STATE_DIR/deploy.sh"
STAGED="$STATE_DIR/staged-build"
if [[ -e "$STAGED" ]]; then mv "$STAGED" "$STAGED.old.$$"; fi
cp -Rc "$IOS_DIR/build" "$STAGED"
rm -rf "$STAGED.old.$$"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$STATE_DIR/deploy.sh</string><string>tick</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/launchd.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
    <key>OPERATOR_AUTO_INSTALL_BRANCH</key><string>$BRANCH</string>
    <key>OPERATOR_ORIGIN_URL</key><string>$ORIGIN_URL</string>
    <key>OPERATOR_STAGED_BUILD</key><string>$STAGED</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
print "installed $LABEL: polls origin/$BRANCH every 5 minutes; log at $STATE_DIR/deploy.log"
