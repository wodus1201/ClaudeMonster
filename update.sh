#!/bin/bash
# Claude Monster — update a source checkout (for developers).
#
# Release users don't need this: the app checks GitHub Releases itself and
# offers "새 버전 설치" in its menu. This pulls + rebuilds from source instead,
# which is why the in-app updater refuses to touch a build/ bundle.
set -euo pipefail
cd "$(dirname "$0")"
SRC_DIR="$(pwd)"
APP="$SRC_DIR/build/ClaudeMonster.app"
source "$SRC_DIR/lib.sh"

echo "==> 1/3  Pulling latest code"
git pull --ff-only

echo "==> 2/3  Rebuilding for this machine"
# Stop the running instance first so the app bundle isn't file-locked mid-build.
stop_all
sleep 1
./build.sh

echo "==> 3/3  Relinking and restarting"
link_to_applications "$APP"
open "$APP"

echo ""
echo "✅  Updated. The 클로드 widget is running the latest version."
