#!/bin/zsh
# ScamShield installer: builds the Mac agent, installs model services, registers
# LaunchAgents and asks for permissions (`--tailscale` optionally publishes the web UI on a tailnet).
# Safe to re-run (upgrades in place; your data and settings are kept).
set -euo pipefail

REPO="${0:A:h:h}"
APP_NAME="ScamShield"
APP="$HOME/Applications/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/ScamShield"
LOGS="$HOME/Library/Logs/ScamShield"
LA="$HOME/Library/LaunchAgents"
SIGN_ID="ScamShield Local Signing"
PORT=8787
UV="$(command -v uv || true)"

say() { print -P "%F{cyan}==>%f $*"; }
warn() { print -P "%F{yellow}!!%f $*"; }

[[ -n "$UV" ]] || { warn "uv is required: brew install uv"; exit 1; }
mkdir -p "$HOME/Applications" "$SUPPORT" "$LOGS" "$LA"

# 1. Stable code-signing identity. macOS ties privacy grants (Full Disk Access, Contacts,
#    Calendar) to the app's signature; a fixed self-signed certificate keeps those grants
#    across rebuilds without needing a paid Apple Developer account.
if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  say "Creating local code-signing certificate \"$SIGN_ID\" (login keychain)"
  TMP=$(mktemp -d)
  cat > "$TMP/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$SIGN_ID
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  PASS=$(openssl rand -hex 12)
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
    || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS"
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"
fi

# 2. Build + sign the app ONLY when its source changed. Signing uses your keychain (macOS may
#    ask for your password), and the web app / prompts live outside the bundle in
#    Application Support so updating them never requires re-signing.
SRC_HASH=$(cd "$REPO/mac" && cat Package.swift Resources/Info.plist Resources/ScamShield.entitlements Resources/AppIcon.icns $(find Sources -name '*.swift' | sort) | shasum -a 256 | cut -d' ' -f1)
for svc in agent decider writer; do launchctl bootout "gui/$UID/com.scamshield.$svc" 2>/dev/null || true; done
if [[ -x "$APP/Contents/MacOS/ScamShieldAgent" && "$(cat "$SUPPORT/.app-source-hash" 2>/dev/null)" == "$SRC_HASH" ]]; then
  say "App unchanged — skipping rebuild and signing"
else
  say "Building Mac agent (release)"
  swift build -c release --package-path "$REPO/mac" 2>&1 | tail -1
  BIN="$(swift build -c release --package-path "$REPO/mac" --show-bin-path)/ScamShieldAgent"
  STAGE="$REPO/build/$APP_NAME.app"
  rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
  cp "$BIN" "$STAGE/Contents/MacOS/ScamShieldAgent"
  cp "$REPO/mac/Resources/Info.plist" "$STAGE/Contents/Info.plist"
  cp "$REPO/mac/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
  if codesign --force --options runtime --timestamp=none --entitlements "$REPO/mac/Resources/ScamShield.entitlements" -s "$SIGN_ID" "$STAGE" 2>/dev/null; then
    say "Signed with \"$SIGN_ID\""
  else
    warn "Could not sign with \"$SIGN_ID\"; falling back to ad-hoc signing (permissions may need re-granting after updates)"
    codesign --force --entitlements "$REPO/mac/Resources/ScamShield.entitlements" -s - "$STAGE"
  fi
  rm -rf "$APP"; cp -R "$STAGE" "$APP"
  echo "$SRC_HASH" > "$SUPPORT/.app-source-hash"
fi

# 3. Web app + model prompts (unsigned resources, updated freely).
mkdir -p "$SUPPORT/resources"
rsync -a --delete --exclude dev "$REPO/web/" "$SUPPORT/resources/web/"
rsync -a --delete "$REPO/brain/prompts/" "$SUPPORT/resources/prompts/"

# 4. Model services (Python env lives in Application Support, independent of this checkout).
say "Installing model services"
mkdir -p "$SUPPORT/brain"
cp "$REPO/brain/pyproject.toml" "$REPO/brain/.python-version" "$SUPPORT/brain/"
[[ -f "$REPO/brain/uv.lock" ]] && cp "$REPO/brain/uv.lock" "$SUPPORT/brain/"
(cd "$SUPPORT/brain" && "$UV" sync --quiet)
PY="$SUPPORT/brain/.venv/bin/python"
# Download weights once (no-op when already cached).
"$PY" - <<'EOF'
from huggingface_hub import snapshot_download
for repo in ["jaredpalmer/kev-4b", "Qwen/Qwen3.5-4B-Base", "mlx-community/Qwen3.5-4B-MLX-4bit"]:
    snapshot_download(repo)
print("models ready")
EOF

# Config: restrict the tailnet app to your Tailscale login; migrate old defaults.
OWNER=$(command -v tailscale >/dev/null && tailscale status --json 2>/dev/null | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["User"][str(d["Self"]["UserID"])]["LoginName"])' 2>/dev/null || true)
"$PY" - "$SUPPORT/config.json" "$OWNER" <<'EOF2'
import json, sys, os
path, owner = sys.argv[1], sys.argv[2]
cfg = json.load(open(path)) if os.path.exists(path) else {}
if owner and not cfg.get("allowedLogins"): cfg["allowedLogins"] = [owner]
if cfg.get("notifyMaxAgeMinutes") == 180: cfg["notifyMaxAgeMinutes"] = 1440
json.dump(cfg, open(path, "w"), indent=2, sort_keys=True)
EOF2

# 5. LaunchAgents.
plist() { # label, log, program args...
  local label=$1 log=$2; shift 2
  local args=""; for a in "$@"; do args+="<string>${a}</string>"; done
  cat > "$LA/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key><dict>
    <key>HF_HUB_OFFLINE</key><string>1</string>
    <key>SCAMSHIELD_RESOURCES</key><string>$SUPPORT/resources</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOGS/$log.log</string>
  <key>StandardErrorPath</key><string>$LOGS/$log.log</string>
</dict></plist>
EOF
}
plist com.scamshield.decider decider "$PY" -m kev.serve --run jaredpalmer/kev-4b --host 127.0.0.1 --port 8009
plist com.scamshield.writer writer "$PY" -m mlx_lm server --model mlx-community/Qwen3.5-4B-MLX-4bit --host 127.0.0.1 --port 8010
plist com.scamshield.agent agent "$APP/Contents/MacOS/ScamShieldAgent"

# Free the ports if dev servers are still running.
for p in 8009 8010 $PORT; do lsof -ti tcp:$p -sTCP:LISTEN | xargs -r kill 2>/dev/null || true; done
for svc in decider writer agent; do launchctl bootstrap "gui/$UID" "$LA/com.scamshield.$svc.plist"; done
say "Services started (logs: $LOGS)"

# 6. Optional: publish the full web app on your tailnet (off by default; iPhone delivery uses
#    Apple Reminders via iCloud). Use: ./scripts/install.sh --tailscale
if [[ "${1:-}" == "--tailscale" ]] && command -v tailscale >/dev/null; then
  if tailscale serve --bg --https=443 "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
    HOST=$(tailscale status --json | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
    say "Web app on your tailnet: https://$HOST/"
  else
    warn "tailscale serve failed — enable HTTPS certificates for your tailnet, then re-run."
  fi
fi
say "On this Mac, the full app is at http://127.0.0.1:$PORT/"

# 7. Contacts, Calendar & Reminders prompts (must be a LaunchServices launch to show dialogs).
SETUP_VERSION=2   # bump when a new permission is added (2: Reminders)
if [[ "$(cat "$SUPPORT/.setup-done" 2>/dev/null)" != "$SETUP_VERSION" ]]; then
  say "Requesting Contacts, Calendar and Reminders access — click Allow in the dialogs"
  SETUP_LOG="$LOGS/setup.log"; : > "$SETUP_LOG"
  open -W --stdout "$SETUP_LOG" --stderr "$SETUP_LOG" "$APP" --args --setup
  RESULT=$(grep "setup:" "$SETUP_LOG" | tail -1)
  say "${RESULT:-setup produced no output}"
  if [[ "$RESULT" == *"reminders=granted"* ]]; then
    echo "$SETUP_VERSION" > "$SUPPORT/.setup-done"
  else
    warn "Reminders access was not granted. Allow ScamShield in System Settings → Privacy & Security → Reminders, then re-run."
  fi
  launchctl kickstart -k "gui/$UID/com.scamshield.agent"
fi

# 8. Permissions check (ask the running agent; it reports read errors in /api/status).
sleep 8
if curl -s "http://127.0.0.1:$PORT/api/status" | grep -q "Full Disk Access"; then
  warn "Grant Full Disk Access to ScamShield: System Settings → Privacy & Security → Full Disk Access → + → $APP"
  print "   then: launchctl kickstart -k gui/$UID/com.scamshield.agent"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" || true
fi
say "Done. Status: curl -s http://127.0.0.1:$PORT/api/status"
