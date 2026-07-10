#!/bin/bash
# Claude Monster — cut a release that the in-app updater can consume.
#
# Builds a universal .app, zips it, and publishes it as a GitHub Release whose
# tag is "v<VERSION>". The app compares its own CFBundleShortVersionString
# against that tag, so the two MUST agree — this script refuses to run if the
# working tree or the tag disagrees with ./VERSION.
#
# Usage:  ./release.sh            # release the version in ./VERSION
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
TAG="v$VERSION"
APP="build/ClaudeMonster.app"
ZIP="build/ClaudeMonster.zip"

command -v gh >/dev/null 2>&1 || {
  echo "✗ GitHub CLI가 필요합니다:  brew install gh && gh auth login"; exit 1; }

echo "==> 1/5  Checking the tree is clean and $TAG is free"
[ -z "$(git status --porcelain)" ] || { echo "✗ 커밋되지 않은 변경이 있습니다."; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "✗ 태그 $TAG 가 이미 있습니다. ./VERSION 을 올리세요."; exit 1
fi

echo "==> 2/5  Building universal (arm64 + x86_64)"
UNIVERSAL=1 ./build.sh
# Guard: a single-arch build here would silently ship a Mac-specific binary.
archs="$(lipo -archs "$APP/Contents/MacOS/ClaudeMonster")"
case "$archs" in
  *arm64*x86_64*|*x86_64*arm64*) echo "    archs: $archs" ;;
  *) echo "✗ universal 빌드 실패 (archs: $archs)"; exit 1 ;;
esac

echo "==> 3/5  Zipping (ditto preserves the bundle layout)"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> 4/5  Tagging $TAG"
git tag -a "$TAG" -m "ClaudeMonster $VERSION"
git push origin "$TAG"

echo "==> 5/5  Publishing the GitHub Release"
gh release create "$TAG" "$ZIP" \
  --title "ClaudeMonster $VERSION" \
  --generate-notes

echo ""
echo "✅  Released $TAG."
echo "    기존 사용자는 앱 메뉴에서 '새 버전 $VERSION 설치'를 보게 됩니다."
