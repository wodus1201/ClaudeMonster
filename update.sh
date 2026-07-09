#!/bin/bash
# Claude Battery — update to the latest version.
# Pulls the newest code, rebuilds for THIS machine, refreshes the LaunchAgent
# (so launch settings never go stale), and restarts the widget.
set -euo pipefail
cd "$(dirname "$0")"
SRC_DIR="$(pwd)"
APP="$SRC_DIR/build/ClaudeBattery.app"
BIN="$APP/Contents/MacOS/ClaudeBattery"
source "$SRC_DIR/lib.sh"

echo "==> 1/4  Pulling latest code"
git pull --ff-only

echo "==> 2/4  Rebuilding for this machine"
# Stop the running instance first so the app bundle isn't file-locked mid-build.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeBattery 2>/dev/null || true
sleep 1
./build.sh

echo "==> 3/4  Refreshing LaunchAgent + /Applications alias"
# Always regenerate the plist so any changed launch settings (KeepAlive, path,
# etc.) are picked up — this is what a plain `git pull` alone would miss.
write_plist "$BIN"
link_to_applications "$APP"

echo "==> 4/4  Restarting with the new binary"
if [ -f "$PLIST" ]; then
  reload_service
else
  echo "    (LaunchAgent not found — run ./install.sh first for auto-start)"
fi

echo ""
echo "✅  Updated. The 클로드 widget is running the latest version."
