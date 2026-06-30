#!/usr/bin/env bash
#
# Kamandar SwiftBar/xbar plugin (TEMPLATE).
#
# Do not run this copy directly — the __PLACEHOLDERS__ are filled in by
# menubar/install-menubar.sh, which writes the rendered file into your SwiftBar
# plugin folder as `kamandar.<interval>.sh` (the interval in the name is how
# SwiftBar/xbar decide how often to re-run it).
#
# It just shells out to `kamandar --menubar`, which prints the menu document.
# HOME + KAMANDAR_CONFIG are exported so the token/login load the same way the
# launchd service does (SwiftBar runs plugins with a minimal environment).
#
# <xbar.title>Kamandar</xbar.title>
# <xbar.desc>Your GitHub work queue in the menu bar.</xbar.desc>
# <xbar.author>Rajan Bhattarai</xbar.author>
# <xbar.author.github>cdrrazan</xbar.author.github>
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
export HOME="__HOME__"
export KAMANDAR_CONFIG="__REPO__/.env"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
exec "__RUBY__" "__REPO__/lib/kamandar.rb" --menubar 2>/dev/null
