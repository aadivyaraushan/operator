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
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$SCRIPT_DIR/deploy.sh</string><string>tick</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/launchd.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
    <key>OPERATOR_AUTO_INSTALL_BRANCH</key><string>$BRANCH</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
print "installed $LABEL: polls origin/$BRANCH every 5 minutes; log at $STATE_DIR/deploy.log"
