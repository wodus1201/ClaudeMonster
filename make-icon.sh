#!/bin/bash
# Claude Monster — regenerate the app icon from the in-app pixel sprite.
#
# The icon is rendered by the app itself (CLAUDEMONSTER_ICON=<path>), so it can
# never drift from the sprite drawn in the menu bar. Run this after changing
# clawdBase / spriteGrids, then commit the resulting icon.icns.
#
# Requires a built app. Usage:  ./build.sh && ./make-icon.sh
set -euo pipefail
cd "$(dirname "$0")"

BIN="build/ClaudeMonster.app/Contents/MacOS/ClaudeMonster"
OUT="icon.icns"
[ -x "$BIN" ] || { echo "✗ 먼저 ./build.sh 를 실행하세요."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/icon.iconset"
mkdir -p "$SET"

echo "==> 1/3  Rendering 1024px master from the sprite"
CLAUDEMONSTER_ICON="$TMP/master.png" "$BIN"
[ -s "$TMP/master.png" ] || { echo "✗ 아이콘 렌더 실패"; exit 1; }

echo "==> 2/3  Scaling to every size iconutil expects"
# iconutil requires these exact names; @2x is the retina variant of the size.
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
  px="${spec%%:*}"; name="${spec##*:}"
  # Nearest-neighbour keeps pixel art crisp instead of blurring it.
  sips -s format png -z "$px" "$px" "$TMP/master.png" \
       --out "$SET/icon_$name.png" >/dev/null
done

echo "==> 3/3  Packing into $OUT"
iconutil -c icns "$SET" -o "$OUT"

echo ""
echo "✅  $OUT 생성 완료. build.sh 가 번들에 자동으로 넣습니다."
