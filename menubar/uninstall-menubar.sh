#!/usr/bin/env bash
# Remove the Kamandar SwiftBar menu-bar plugin (any refresh interval).
set -euo pipefail

PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$PLUGIN_DIR" ] || [ ! -d "$PLUGIN_DIR" ]; then
  echo "kamandar: no SwiftBar plugin folder found — nothing to remove."
  exit 0
fi

removed=0
for f in "$PLUGIN_DIR"/kamandar.*.sh; do
  [ -e "$f" ] || continue
  rm -f "$f"
  removed=1
done

open -g "swiftbar://refreshallplugins" 2>/dev/null || true

if [ "$removed" -eq 1 ]; then
  echo "kamandar: menu-bar plugin removed from $PLUGIN_DIR"
else
  echo "kamandar: no kamandar plugin found in $PLUGIN_DIR"
fi
