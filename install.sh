#!/bin/bash
# Claude Battery — one-shot installer. Works on any Mac (Apple Silicon or Intel):
# it builds a binary for THIS machine, registers a login-item that auto-starts
# the widget, and drops a clickable alias in /Applications.
set -euo pipefail
cd "$(dirname "$0")"
SRC_DIR="$(pwd)"
APP="$SRC_DIR/build/ClaudeBattery.app"
BIN="$APP/Contents/MacOS/ClaudeBattery"
source "$SRC_DIR/lib.sh"

echo "==> 1/5  Checking prerequisites"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "    Swift compiler not found. Installing Xcode Command Line Tools…"
  echo "    (a system dialog will appear — click Install, then re-run ./install.sh)"
  xcode-select --install || true
  exit 1
fi
echo "    swiftc: $(swiftc --version 2>/dev/null | head -1)"

echo "==> 2/5  Stopping any previous instance (so the rebuild isn't file-locked)"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeBattery 2>/dev/null || true
sleep 1

echo "==> 3/5  Building the app for this machine"
./build.sh

echo "==> 4/5  Registering auto-start + /Applications alias"
write_plist "$BIN"
link_to_applications "$APP"

echo "==> 5/5  Starting"
reload_service

echo ""
echo "✅  Done. Look at the right side of your menu bar for the 클로드 HP widget."
echo "    It auto-starts at login, and 'ClaudeBattery' is now clickable in Launchpad."
echo ""
echo "    Requires: you must be logged into Claude Code on this machine"
echo "    (the app reads the OAuth token from your Keychain — same one the CLI uses)."
echo "    The first launch may pop a Keychain access prompt → click \"Always Allow\"."
