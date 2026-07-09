#!/bin/bash
# Claude Battery — one-shot installer. Works on any Mac (Apple Silicon or Intel):
# it builds a binary for THIS machine, then registers a login-item that
# auto-starts the app and keeps it alive.
set -euo pipefail
cd "$(dirname "$0")"
SRC_DIR="$(pwd)"
APP="$SRC_DIR/build/ClaudeBattery.app"
BIN="$APP/Contents/MacOS/ClaudeBattery"
LABEL="com.jay.ClaudeBattery"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 1/5  Checking prerequisites"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "    Swift compiler not found. Installing Xcode Command Line Tools…"
  echo "    (a system dialog will appear — click Install, then re-run ./install.sh)"
  xcode-select --install || true
  exit 1
fi
echo "    swiftc: $(swiftc --version 2>/dev/null | head -1)"

echo "==> 2/5  Stopping any previous instance (so the rebuild isn't file-locked)"
launchctl unload "$PLIST" 2>/dev/null || true
pkill -x ClaudeBattery 2>/dev/null || true
sleep 1

echo "==> 3/5  Building the app for this machine"
./build.sh

echo "==> 4/5  Registering auto-start (LaunchAgent)"
mkdir -p "$HOME/Library/LaunchAgents"
# Generate the plist with THIS machine's real path (no hardcoded username).
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Auto-restart only on a crash. A clean quit (menu "종료") stays quit,
         so the user can turn it off without launchd immediately reviving it. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLISTEOF

echo "==> 5/5  Starting"
# Fully re-register: bootout removes any existing registration (modern API),
# then bootstrap loads the fresh plist. Falls back to legacy load if needed.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
  || { launchctl unload "$PLIST" 2>/dev/null || true; launchctl load -w "$PLIST"; }
# Ensure it's running the just-built binary right now.
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo ""
echo "✅  Done. Look at the right side of your menu bar for the 클로드 HP widget."
echo "    It auto-starts at login from:"
echo "      $BIN"
echo ""
echo "    Requires: you must be logged into Claude Code on this machine"
echo "    (the app reads the OAuth token from your Keychain — same one the CLI uses)."
echo "    The first launch may pop a Keychain access prompt → click \"Always Allow\"."
