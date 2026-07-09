#!/bin/bash
# Claude Battery — stop the widget and keep it stopped.
# Unlike `pkill` (which launchd immediately revives), this unregisters the
# service so it stays off until you run ./start.sh (or log in again with the
# plist still installed). Use ./uninstall.sh to also disable login auto-start.
set -euo pipefail
LABEL="com.jay.ClaudeBattery"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeBattery 2>/dev/null || true
echo "✅  Stopped. Run ./start.sh to turn it back on."
