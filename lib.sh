#!/bin/bash
# Claude Monster — shared helpers used by install.sh / update.sh.
# Not meant to be run directly; sourced by the other scripts.

# The app was "ClaudeBattery" before 1.2 and its installer registered a
# LaunchAgent. Auto-start now lives in the app (SMAppService, via the
# "로그인 시 자동 시작" menu toggle), so these names exist ONLY to clean up
# what an old install left behind. They are historical — do not rename them.
LEGACY_LABEL="com.jay.ClaudeBattery"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_PROC="ClaudeBattery"

# Stop every copy of the widget: the current one, plus any pre-1.2 build still
# running under the old executable name (pkill -x matches the exact name).
stop_all() {
  launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
  pkill -x ClaudeMonster 2>/dev/null || true
  pkill -x "$LEGACY_PROC" 2>/dev/null || true
}

# Put a clickable alias in /Applications so the app shows up in Launchpad /
# Spotlight and can be double-clicked to launch, without moving the source.
link_to_applications() {
  local app="$1"
  local dest="/Applications/ClaudeMonster.app"
  # Drop the pre-1.2 entry so Launchpad doesn't keep showing a dead icon.
  rm -rf "/Applications/ClaudeBattery.app" 2>/dev/null || true
  # Remove a stale link/copy, then symlink the real bundle.
  if [ -L "$dest" ] || [ -e "$dest" ]; then rm -rf "$dest" 2>/dev/null || true; fi
  ln -s "$app" "$dest" 2>/dev/null \
    && echo "    Linked into /Applications (Launchpad/Spotlight에서 'ClaudeMonster' 검색 가능)" \
    || echo "    (/Applications 링크 생략 — 권한 문제 시 수동으로 앱을 드래그하세요)"
}
