#!/usr/bin/env bash
# Install Kamandar as a persistent per-user web app via launchd.
#
# Renders service/com.kamandar.serve.plist (filling in this machine's repo path,
# ruby binary, and home), writes it to ~/Library/LaunchAgents, and bootstraps it.
# Idempotent: re-running re-renders and reloads. Requires a populated .env in the
# repo root (token + login) — run `ruby lib/kamandar.rb --init` first if missing.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME"
RUBY="$(command -v ruby)"
LABEL="com.kamandar.serve"
TEMPLATE="$REPO/service/$LABEL.plist"
DEST="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ ! -f "$REPO/.env" ]; then
  echo "error: $REPO/.env not found. Create it (token + login) first, e.g.:" >&2
  echo "  ruby \"$REPO/lib/kamandar.rb\" --init   # then copy ~/.config/kamandar/config to .env" >&2
  exit 1
fi

mkdir -p "$HOME_DIR/Library/LaunchAgents"

# Render the template — sed with a non-/ delimiter so paths with / are safe.
sed -e "s#__RUBY__#$RUBY#g" \
    -e "s#__REPO__#$REPO#g" \
    -e "s#__HOME__#$HOME_DIR#g" \
    "$TEMPLATE" > "$DEST"

# Reload cleanly: ignore "not loaded" on first run.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# Reap any orphaned kamandar tunnel from a hard-killed prior run before respawn.
pkill -f "cloudflared tunnel run kamandar" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$DEST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

PORT="$(grep -E '^PORT=' "$REPO/.env" | head -1 | cut -d= -f2 | tr -d '"' || true)"
PORT="${PORT:-4567}"
echo "kamandar: service '$LABEL' loaded — http://127.0.0.1:$PORT"
echo "kamandar: logs at $HOME_DIR/Library/Logs/kamandar.{out,err}.log"
echo "kamandar: stop/remove with service/uninstall-service.sh"
