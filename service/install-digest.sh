#!/usr/bin/env bash
# Schedule the Kamandar daily-summary email via launchd.
#
# Renders service/com.kamandar.digest.plist (filling in this machine's repo
# path, ruby binary, home, zone, and the send time), writes it to
# ~/Library/LaunchAgents, and bootstraps it. Runs `kamandar --email` once a day
# at the given time (default 22:00 / 10 PM). Idempotent: re-running re-renders
# and reloads.
#
# Usage:  ./service/install-digest.sh [HH:MM]
#         ./service/install-digest.sh 22:00   # default
#         ./service/install-digest.sh 09:30
#
# Requires a populated .env with the token + SMTP config (SMTP_HOST, SMTP_USER,
# SMTP_PASS, MAIL_TO). Run `ruby lib/kamandar.rb --init` first to fill it in.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME"
RUBY="$(command -v ruby)"
LABEL="com.kamandar.digest"
TEMPLATE="$REPO/service/$LABEL.plist"
DEST="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

WHEN="${1:-22:00}"
if ! [[ "$WHEN" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
  echo "error: time must be HH:MM (24-hour), e.g. 22:00 — got '$WHEN'." >&2
  exit 1
fi
HOUR="$((10#${BASH_REMATCH[1]}))"
MIN="$((10#${BASH_REMATCH[2]}))"
if [ "$HOUR" -gt 23 ] || [ "$MIN" -gt 59 ]; then
  echo "error: '$WHEN' is not a valid 24-hour time." >&2
  exit 1
fi

if [ ! -f "$REPO/.env" ]; then
  echo "error: $REPO/.env not found. Create it (token + SMTP config) first:" >&2
  echo "  ruby \"$REPO/lib/kamandar.rb\" --init" >&2
  exit 1
fi

mkdir -p "$HOME_DIR/Library/LaunchAgents"

# Pin the machine's IANA zone (from /etc/localtime) so the digest clock is local.
TZID="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
[ -n "$TZID" ] || TZID="UTC"

# Render the template — sed with a non-/ delimiter so paths with / are safe.
sed -e "s#__RUBY__#$RUBY#g" \
    -e "s#__REPO__#$REPO#g" \
    -e "s#__HOME__#$HOME_DIR#g" \
    -e "s#__TZ__#$TZID#g" \
    -e "s#__HOUR__#$HOUR#g" \
    -e "s#__MIN__#$MIN#g" \
    "$TEMPLATE" > "$DEST"

# Reload cleanly: ignore "not loaded" on first run, then settle + retry once.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
sleep 1
if ! launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
  sleep 2
  launchctl bootstrap "$DOMAIN" "$DEST"
fi
launchctl enable "$DOMAIN/$LABEL"

printf 'kamandar: daily summary scheduled for %02d:%02d (%s)\n' "$HOUR" "$MIN" "$TZID"
echo "kamandar: test it now with  ruby \"$REPO/lib/kamandar.rb\" --email"
echo "kamandar: logs at $HOME_DIR/Library/Logs/kamandar.digest.{out,err}.log"
echo "kamandar: stop/remove with service/uninstall-digest.sh"
