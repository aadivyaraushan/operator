#!/bin/zsh
# Deploy the location-enabled operator-phone-runtime to the Pixel 9 and refresh
# the OpenClaw plugin's tool list so the agent sees the new `location` tool.
#
# Safe by construction: backs up the live binary, restarts under runit, health-
# checks, and AUTO-ROLLS-BACK if the runtime does not come back healthy.
#
# Prereqs: Pixel on USB (adb), Termux sshd up on 8022, phone unlocked.
# Cost: sync-tools + the agent tool-list check hit the ChatGPT subscription
# (ssdear@gmail.com, flat-rate, no per-call dollar cost). A handful of calls.
set -euo pipefail

SERIAL=4B230DLAQ001Z5
REPO="/Users/aadivyar/Documents/Startups/ai native mobile software/codex-launcher"
KEY="$REPO/.claude/worktrees/phase0-notification-probe/saved-results/wave0-phone-4B230DLAQ001Z5/bootstrap/termux_ed25519"
BINARY="/private/tmp/claude-501/-Users-aadivyar/8e4b0bd9-ad03-47f4-b975-4938c05ab76d/scratchpad/operator-phone-runtime-linux-arm64"
EXPECT_SHA="a77191b925bde6e2fdbea9c64cfef57e5f3475333642b71d6f970aa9c7620102"
SSH="ssh -i $KEY -p 18022 -o StrictHostKeyChecking=no u0_a451@127.0.0.1"

echo "== 1. adb forwards =="
adb -s "$SERIAL" forward --remove-all
adb -s "$SERIAL" forward tcp:18022 tcp:8022
adb -s "$SERIAL" forward tcp:19443 tcp:9443

echo "== 2. copy new binary into Termux home =="
scp -i "$KEY" -P 18022 -o StrictHostKeyChecking=no "$BINARY" u0_a451@127.0.0.1:'~/operator-phone-runtime.new'
GOT_SHA=$($SSH 'sha256sum ~/operator-phone-runtime.new | cut -d" " -f1')
[ "$GOT_SHA" = "$EXPECT_SHA" ] || { echo "SHA MISMATCH on phone ($GOT_SHA); aborting"; exit 1; }
echo "sha verified on phone: $GOT_SHA"

echo "== 3. install + restart + health-check + auto-rollback (inside proot) =="
$SSH 'proot-distro login debian -- bash -s' <<'PROOT'
set -euo pipefail
export SVDIR=/etc/operator/services
NEW=/data/data/com.termux/files/home/operator-phone-runtime.new
TARGET=/usr/local/bin/operator-phone-runtime
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=${TARGET}.bak-${STAMP}

cp -a "$TARGET" "$BACKUP"
echo "backed up live binary -> $BACKUP ($(sha256sum $BACKUP | cut -d' ' -f1))"
install -m 0755 "$NEW" "$TARGET"
echo "installed new binary ($(sha256sum $TARGET | cut -d' ' -f1))"
sv restart phone-runtime

# Health: sv must report 'run' with uptime climbing (not crash-looping), and
# 9443 must accept a TCP connection. Check over ~12s.
ok=0
for i in $(seq 1 12); do
  sleep 1
  st=$(sv status phone-runtime || true)
  secs=$(echo "$st" | grep -oE '[0-9]+s' | head -1 | tr -d s || echo 0)
  if echo "$st" | grep -q '^run:' && [ "${secs:-0}" -ge 4 ] && (exec 3<>/dev/tcp/127.0.0.1/9443) 2>/dev/null; then
    ok=1; echo "healthy: $st"; break
  fi
done
if [ "$ok" -ne 1 ]; then
  echo "UNHEALTHY after restart — rolling back"
  install -m 0755 "$BACKUP" "$TARGET"
  sv restart phone-runtime
  sleep 3
  echo "rolled back to $BACKUP; status: $(sv status phone-runtime)"
  exit 1
fi
echo "PHONE-RUNTIME DEPLOY OK (backup kept at $BACKUP)"
PROOT

echo "== 4. regenerate plugin tool list against the live bridge (sync-tools) =="
$SSH 'proot-distro login debian -- bash -s' <<'PROOT'
set -euo pipefail
cd /root/operator-tools
npm run build >/dev/null 2>&1 || true
BRIDGE_URL=https://127.0.0.1:9443 \
  TOKEN_PATH=/var/lib/operator-phone/agentbridge-token \
  CERT_PATH=/var/lib/operator-phone/agentbridge-cert.pem \
  npm run sync-tools
echo "location present in tools.json: $(grep -c '"location"' src/tools.json)"
# reinstall so the running gateway picks up the refreshed tool table
openclaw plugins install . 2>&1 | tail -2 || true
PROOT

echo "== DONE. Verify on the agent side next (deny->permission_denied, grant->fix). =="
