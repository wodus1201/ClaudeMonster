#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeMonster.app"
BIN="$APP/Contents/MacOS/ClaudeMonster"

# Single source of truth for the version. The app compares this against the
# latest GitHub Release to offer in-app updates, so VERSION must match the
# release tag (tag "v1.1" ⇒ VERSION=1.1). ./release.sh enforces that.
VERSION="$(cat VERSION)"

# UNIVERSAL=1 builds a fat binary (Apple Silicon + Intel) for distribution.
# Plain ./build.sh stays single-arch: it's much faster for local iteration.
UNIVERSAL="${UNIVERSAL:-0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Info.plist — LSUIElement=1 makes it a menu-bar-only agent (no dock icon).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeMonster</string>
    <key>CFBundleDisplayName</key>     <string>Claude Monster</string>
    <key>CFBundleIdentifier</key>      <string>com.jay.ClaudeMonster</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>ClaudeMonster</string>
    <key>CFBundleIconFile</key>        <string>icon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

if [ "$UNIVERSAL" = "1" ]; then
  echo "Compiling (universal: arm64 + x86_64)…"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  swiftc -O -target arm64-apple-macos13  src/main.swift -o "$TMP/arm64"
  swiftc -O -target x86_64-apple-macos13 src/main.swift -o "$TMP/x86_64"
  lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
else
  echo "Compiling…"
  swiftc -O src/main.swift -o "$BIN"
fi
chmod +x "$BIN"

# Bundle the pixel font (NeoDunggeunmo) so the app is self-contained.
mkdir -p "$APP/Contents/Resources"
cp fonts/neodgm.ttf "$APP/Contents/Resources/neodgm.ttf"

# App icon, if it's been generated (./make-icon.sh). Optional so a fresh clone
# still builds; without it macOS just shows the generic app icon.
if [ -f icon.icns ]; then
  cp icon.icns "$APP/Contents/Resources/icon.icns"
fi

# Must come after every file is in place, or the signature won't cover them.
# Ad-hoc code signature so macOS lets it run without Gatekeeper nagging.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
