#!/usr/bin/env bash
# Stop and remove the Kamandar daily-summary LaunchAgent. Leaves .env + logs alone.
set -euo pipefail

LABEL="com.kamandar.digest"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$DEST"
echo "kamandar: daily summary '$LABEL' unscheduled and removed."
