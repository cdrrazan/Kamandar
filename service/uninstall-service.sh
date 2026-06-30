#!/usr/bin/env bash
# Stop and remove the Kamandar launchd web-app service. Leaves .env + logs alone.
set -euo pipefail

LABEL="com.kamandar.serve"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# Reap the tunnel child too, in case launchd hard-killed the parent (no ensure).
pkill -f "cloudflared tunnel run kamandar" 2>/dev/null || true
rm -f "$DEST"
echo "kamandar: service '$LABEL' stopped and removed (tunnel reaped)."
