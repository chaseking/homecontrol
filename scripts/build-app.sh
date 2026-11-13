#!/bin/bash
# Builds build/HomeControl.app (menu bar app) and makes sure the backend venv exists.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --open     build, then (re)launch the app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/HomeControl.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

[ -x "$ROOT/backend/.venv/bin/python" ] || "$ROOT/scripts/setup-backend.sh"

cd "$ROOT/macos"
build() { swift build -c release --build-system native "$@" 2>&1 | grep -vE "deprecated and will be removed" ; return "${PIPESTATUS[0]}"; }
if ! build >/tmp/homecontrol-build.log 2>&1; then
  # Command Line Tools without Xcode can't expand SwiftUI macros from the newest SDK;
  # fall back to the newest SDK whose SwiftUI doesn't need them.
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "$SDK" ] && grep -q "SwiftUIMacros" /tmp/homecontrol-build.log; then
    echo "note: building against $(basename "$SDK") (no Xcode installed)"
    SDKROOT="$SDK" build || { echo "build failed"; exit 1; }
  else
    cat /tmp/homecontrol-build.log; exit 1
  fi
fi
BIN="$(swift build -c release --build-system native --show-bin-path 2>/dev/null)/HomeControl"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/macos/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/HomeControl"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HomeControl</string>
  <key>CFBundleDisplayName</key><string>HomeControl</string>
  <key>CFBundleIdentifier</key><string>local.homecontrol.app</string>
  <key>CFBundleExecutable</key><string>HomeControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>HomeControl talks to your Hue bridge and Kasa plugs on the local network.</string>
  <key>HCProjectRoot</key><string>$ROOT</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $APP (v$VERSION)"

if [ "${1:-}" = "--open" ]; then
  pkill -x HomeControl 2>/dev/null && sleep 1 || true
  open "$APP"
fi
