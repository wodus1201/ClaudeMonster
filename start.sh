#!/bin/bash
# Claude Monster — start (or restart) the widget after ./stop.sh.
set -euo pipefail
cd "$(dirname "$0")"
source "$(pwd)/lib.sh"

APP="$(pwd)/build/ClaudeMonster.app"
[ -d "$APP" ] || { echo "빌드가 없습니다 — 먼저 ./install.sh 를 실행하세요."; exit 1; }

stop_all
sleep 0.3
open "$APP"
echo "✅  Started. Look for the 클로드 widget in the menu bar."
