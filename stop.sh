#!/bin/bash
# Claude Monster — stop the widget.
#
# Auto-start now lives in SMAppService (the "로그인 시 자동 시작" menu toggle),
# not in a LaunchAgent, so nothing revives the app after this. stop_all also
# reaps a pre-1.2 "ClaudeBattery" build and its leftover LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
source "$(pwd)/lib.sh"

stop_all
echo "✅  Stopped. Run ./start.sh to turn it back on."
