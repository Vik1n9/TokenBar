#!/usr/bin/env bash
# Builds the app and produces both distributable artifacts:
#   .dmg — the conventional macOS drag-to-Applications installer
#   .zip — for anyone scripting a download, and for CI artifacts
# Usage: scripts/package-release.sh [version]   (default: CFBundleShortVersionString)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-app.sh"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
DMG="$ROOT/dist/TokenBar-$VERSION.dmg"
ZIP="$ROOT/dist/TokenBar-$VERSION.zip"
STAGE="$ROOT/dist/dmg-staging"

# Staging holds exactly what the mounted volume should show: the app, and a
# shortcut to /Applications to drag it into.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/TokenBar.app" "$STAGE/TokenBar.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "TokenBar" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

rm -rf "$STAGE"

hdiutil verify -quiet "$DMG"

# ditto keeps the bundle's symlinks and extended attributes intact.
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/dist/TokenBar.app" "$ZIP"

echo "Packaged:"
shasum -a 256 "$DMG" "$ZIP"
