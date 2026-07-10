#!/bin/bash
# Claude Monster — stop the app and remove auto-start.
set -euo pipefail
cd "$(dirname "$0")"
source "$(pwd)/lib.sh"

stop_all
rm -f "$LEGACY_PLIST"

# The /Applications entry is a symlink for source installs, a real bundle for
# release installs. Removing either is safe; the source folder is untouched.
# ClaudeBattery.app is the pre-1.2 name, left behind by an old install.
rm -rf /Applications/ClaudeMonster.app /Applications/ClaudeBattery.app 2>/dev/null || true

echo "✅  Uninstalled (app stopped, /Applications entry removed)."
echo ""
echo "    자동 시작(로그인 항목)이 남아 있다면 한 번만 정리해 주세요:"
echo "    시스템 설정 → 일반 → 로그인 항목 → ClaudeMonster 제거"
echo "    (앱이 이미 삭제되어 SMAppService 등록을 코드로 해제할 수 없습니다.)"
echo ""
echo "    The source folder is untouched — delete it manually if you want."
