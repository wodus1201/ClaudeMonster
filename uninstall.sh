#!/bin/bash
# Claude Battery — remove the auto-start login item and stop the app.
set -euo pipefail
LABEL="com.jay.ClaudeBattery"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# bootout reliably unregisters the service (unlike legacy unload); then remove
# the plist so it won't auto-start at the next login either.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
pkill -x ClaudeBattery 2>/dev/null || true

echo "✅  Uninstalled (login item removed, app stopped)."
echo "    The source folder is untouched — delete it manually if you want."
