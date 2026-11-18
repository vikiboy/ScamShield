#!/bin/zsh
# Builds the ScamShield iPhone app with your free Apple ID ("Personal Team") and installs it on
# your iPhone. Free-team installs expire after 7 days, so `--refresh` (run by a LaunchAgent every
# 6 h) reinstalls when the current install is 4+ days old and the iPhone is reachable
# (USB, or same Wi-Fi with "Connect via network" enabled in Xcode → Devices).
#
#   ./scripts/ios-install.sh            build + install now (first time: iPhone on USB)
#   ./scripts/ios-install.sh --refresh  reinstall only if due and the iPhone is reachable
#   ./scripts/ios-install.sh --schedule install the auto-refresh LaunchAgent
set -euo pipefail

REPO="${0:A:h:h}"
SUPPORT="$HOME/Library/Application Support/ScamShield"
LOGS="$HOME/Library/Logs/ScamShield"
STATE="$SUPPORT/ios-install.json"
DERIVED="$SUPPORT/ios-build"
mkdir -p "$SUPPORT" "$LOGS"
say() { print -P "%F{cyan}==>%f $*"; }
warn() { print -P "%F{yellow}!!%f $*"; }
MODE="${1:-}"

if [[ "$MODE" == "--schedule" ]]; then
  # Background jobs can't read ~/Desktop or ~/Documents (macOS privacy), so the refresh job
  # runs from its own copy of the iPhone project in Application Support.
  COPY="$SUPPORT/ios-refresh"
  mkdir -p "$COPY/scripts"
  rsync -a --delete --exclude '*.xcodeproj/xcuserdata' --exclude 'build' "$REPO/ios/" "$COPY/ios/"
  cp "${0:A}" "$COPY/scripts/ios-install.sh"
  PL="$HOME/Library/LaunchAgents/com.scamshield.ios-refresh.plist"
  cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.scamshield.ios-refresh</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$COPY/scripts/ios-install.sh</string><string>--refresh</string></array>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string></dict>
  <key>StandardOutPath</key><string>$LOGS/ios-refresh.log</string>
  <key>StandardErrorPath</key><string>$LOGS/ios-refresh.log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$UID/com.scamshield.ios-refresh" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PL"
  say "Auto-refresh scheduled (every 6 h; reinstalls when 4+ days old). Log: $LOGS/ios-refresh.log"
  exit 0
fi

# Free "Personal Team" from Xcode's signed-in account.
TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -A3 -i "isFreeProvisioningTeam = 1" | grep -o 'teamID = [A-Z0-9]*' | head -1 | awk '{print $3}' || true)
[[ -z "$TEAM" ]] && TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -o 'teamID = [A-Z0-9]*' | head -1 | awk '{print $3}' || true)
if [[ -z "$TEAM" ]]; then
  warn "No Apple ID found in Xcode. Open Xcode → Settings → Accounts → + → Apple ID, sign in, then re-run."
  exit 2
fi
BUNDLE="com.scamshield.$(print -r -- "$TEAM" | tr 'A-Z' 'a-z').app"

# Find the iPhone (paired; connected by USB or reachable over the network).
DEVJSON=$(mktemp); xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1 || true
DEVICE=$(/usr/bin/python3 - "$DEVJSON" <<'EOF'
import json, sys
try: devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devs = []
ok = [d for d in devs if d.get("hardwareProperties", {}).get("platform") == "iOS"
      and d.get("hardwareProperties", {}).get("reality") == "physical"
      and d.get("connectionProperties", {}).get("tunnelState") in ("connected", "disconnected")
      and d.get("connectionProperties", {}).get("pairingState") == "paired"]
ok.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
print(ok[0]["identifier"] if ok else "")
EOF
); rm -f "$DEVJSON"

if [[ "$MODE" == "--refresh" ]]; then
  AGE=$(/usr/bin/python3 -c "import json,time,sys; d=json.load(open(sys.argv[1])); print(int((time.time()-d['installedAt'])/86400))" "$STATE" 2>/dev/null || echo 99)
  if (( AGE < 4 )); then echo "$(date): install is $AGE days old; nothing to do"; exit 0; fi
  if [[ -z "$DEVICE" ]]; then echo "$(date): due (age $AGE d) but iPhone not reachable; will retry"; exit 0; fi
  echo "$(date): refreshing (age $AGE d)"
fi
[[ -n "$DEVICE" ]] || { warn "iPhone not found. Connect it by USB, unlock it, tap Trust, and enable Developer Mode (Settings → Privacy & Security)."; exit 3; }

say "Building ScamShield for iPhone (team $TEAM, bundle $BUNDLE)"
(cd "$REPO/ios" && xcodegen generate --quiet)
xcodebuild -project "$REPO/ios/ScamShield.xcodeproj" -scheme ScamShield -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" CODE_SIGN_STYLE=Automatic \
  SCAMSHIELD_LAN_TOKEN="$(cat "$SUPPORT/lan.token" 2>/dev/null)" build -quiet
APPPATH="$DERIVED/Build/Products/Release-iphoneos/ScamShield.app"

say "Installing on iPhone"
xcrun devicectl device install app --device "$DEVICE" "$APPPATH" >/dev/null
/usr/bin/python3 -c "import json,time,sys; json.dump({'installedAt': time.time(), 'team': sys.argv[2], 'bundle': sys.argv[3]}, open(sys.argv[1],'w'))" "$STATE" "$TEAM" "$BUNDLE"
say "Installed. Valid until $(date -v+7d '+%a %b %d'); the Mac reinstalls automatically before then."
