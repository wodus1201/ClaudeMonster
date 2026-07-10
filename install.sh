#!/bin/bash
# Claude Monster — build-from-source installer (for developers).
#
# End users don't need this: they download ClaudeMonster.zip from the Releases
# page, drag the .app to /Applications, and use the menu to enable auto-start
# and updates. This script is for running the app straight from a checkout.
#
# Auto-start is NOT registered here — the app owns it via SMAppService, exposed
# as the "로그인 시 자동 시작" menu toggle. A LaunchAgent left by a pre-1.2
# "ClaudeBattery" install is retired automatically on first launch.
set -euo pipefail
cd "$(dirname "$0")"
SRC_DIR="$(pwd)"
APP="$SRC_DIR/build/ClaudeMonster.app"
source "$SRC_DIR/lib.sh"

echo "==> 1/4  Checking prerequisites"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "    Swift compiler not found. Installing Xcode Command Line Tools…"
  echo "    (a system dialog will appear — click Install, then re-run ./install.sh)"
  xcode-select --install || true
  exit 1
fi
echo "    swiftc: $(swiftc --version 2>/dev/null | head -1)"

echo "==> 2/4  Stopping any previous instance (so the rebuild isn't file-locked)"
stop_all
sleep 1

echo "==> 3/4  Building the app for this machine"
./build.sh

echo "==> 4/4  Linking into /Applications and starting"
link_to_applications "$APP"
open "$APP"

echo ""
echo "✅  Done. Look at the right side of your menu bar for the 클로드 HP widget."
echo "    자동 시작은 위젯 메뉴의 '로그인 시 자동 시작'으로 켜세요."
echo ""
echo "    Requires: you must be logged into Claude Code on this machine"
echo "    (the app reads the OAuth token from your Keychain — same one the CLI uses)."
echo "    The first launch may pop a Keychain access prompt → click \"Always Allow\"."
