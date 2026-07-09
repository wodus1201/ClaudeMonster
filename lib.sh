#!/bin/bash
# Claude Battery — shared helpers used by install.sh / update.sh.
# Not meant to be run directly; sourced by the other scripts.

LABEL="com.jay.ClaudeBattery"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Regenerate the LaunchAgent plist for THIS machine (real $HOME path, current
# KeepAlive policy). Called by both install and update so the plist is never
# stale — that's what used to make an updated build keep old launch settings.
# Arg 1: absolute path to the ClaudeBattery binary.
write_plist() {
  local bin="$1"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$bin</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Auto-restart only on a crash. A clean quit (menu "종료" / ./stop.sh)
         stays quit, so it isn't revived the instant you turn it off. -->
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
}

# Register + (re)start the service reliably, running the freshly built binary.
reload_service() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || { launchctl unload "$PLIST" 2>/dev/null || true; launchctl load -w "$PLIST"; }
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
}

# Put a clickable alias in /Applications so the app shows up in Launchpad /
# Spotlight and can be double-clicked to launch, without moving the source.
link_to_applications() {
  local app="$1"
  local dest="/Applications/ClaudeBattery.app"
  # Remove a stale link/copy, then symlink the real bundle.
  if [ -L "$dest" ] || [ -e "$dest" ]; then rm -rf "$dest" 2>/dev/null || true; fi
  ln -s "$app" "$dest" 2>/dev/null \
    && echo "    Linked into /Applications (Launchpad/Spotlight에서 'ClaudeBattery' 검색 가능)" \
    || echo "    (/Applications 링크 생략 — 권한 문제 시 수동으로 앱을 드래그하세요)"
}
