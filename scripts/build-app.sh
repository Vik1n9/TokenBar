#!/usr/bin/env bash
# Builds TokenBar.app into dist/. WKWebView needs a real bundle, so the
# SwiftPM binary is wrapped rather than run bare.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/TokenBar.app"

cd "$ROOT"

# Universal, so the release also runs on Intel Macs down to the deployment
# target rather than only on Apple Silicon.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/TokenBar" "$APP/Contents/MacOS/TokenBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature keeps macOS from killing the app on launch.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
