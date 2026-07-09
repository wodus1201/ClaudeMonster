#!/bin/bash
# Claude Battery — start (or restart) the widget after ./stop.sh.
set -euo pipefail
cd "$(dirname "$0")"
LABEL="com.jay.ClaudeBattery"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -f "$PLIST" ]; then
  echo "LaunchAgent not installed yet — run ./install.sh first."
  exit 1
fi

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
echo "✅  Started. Look for the 클로드 widget in the menu bar."
