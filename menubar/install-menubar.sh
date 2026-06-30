#!/usr/bin/env bash
# Install Kamandar as a SwiftBar menu-bar plugin.
#
# Renders menubar/kamandar.plugin.sh (filling in this machine's repo/ruby/home)
# into your SwiftBar plugin folder as `kamandar.<interval>.sh`, then asks SwiftBar
# to refresh. Requires SwiftBar (https://swiftbar.app, `brew install swiftbar`)
# with a plugin folder already chosen, and a populated repo .env (token + login).
#
# Usage: ./menubar/install-menubar.sh [interval]   # interval e.g. 2m, 5m, 30s (default 5m)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUBY="$(command -v ruby)"
TEMPLATE="$REPO/menubar/kamandar.plugin.sh"
INTERVAL="${1:-5m}"

if [ ! -f "$REPO/.env" ]; then
  echo "error: $REPO/.env not found — create it (token + login) first:" >&2
  echo "  ruby \"$REPO/lib/kamandar.rb\" --init && cp ~/.config/kamandar/config \"$REPO/.env\"" >&2
  exit 1
fi

# SwiftBar stores its plugin folder in its prefs. Read it; bail with guidance if unset.
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$PLUGIN_DIR" ] || [ ! -d "$PLUGIN_DIR" ]; then
  echo "error: couldn't find your SwiftBar plugin folder." >&2
  echo "  Install SwiftBar (brew install swiftbar), launch it, and pick a plugin" >&2
  echo "  folder when prompted. Then re-run this script." >&2
  exit 1
fi

DEST="$PLUGIN_DIR/kamandar.$INTERVAL.sh"
sed -e "s#__RUBY__#$RUBY#g" \
    -e "s#__REPO__#$REPO#g" \
    -e "s#__HOME__#$HOME#g" \
    "$TEMPLATE" > "$DEST"
chmod +x "$DEST"

# Nudge SwiftBar to pick up the new plugin (URL scheme; harmless if it's closed).
open -g "swiftbar://refreshallplugins" 2>/dev/null || true

echo "kamandar: menu-bar plugin installed → $DEST"
echo "kamandar: refreshes every $INTERVAL. Remove with menubar/uninstall-menubar.sh"
