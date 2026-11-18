#!/bin/zsh
# Removes ScamShield services and app. Keeps your data unless --purge is given.
set -uo pipefail
for svc in agent decider writer; do
  launchctl bootout "gui/$UID/com.scamshield.$svc" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/com.scamshield.$svc.plist"
done
command -v tailscale >/dev/null && tailscale serve --https=443 off 2>/dev/null
rm -rf "$HOME/Applications/ScamShield.app"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/Library/Application Support/ScamShield" "$HOME/Library/Logs/ScamShield" "$HOME/Library/Caches/ScamShield"
  security delete-certificate -c "ScamShield Local Signing" 2>/dev/null
  echo "ScamShield removed, including data."
else
  echo "ScamShield removed. Data kept in ~/Library/Application Support/ScamShield (use --purge to delete)."
fi
