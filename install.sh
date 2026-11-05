#!/bin/bash
# Build Ember Bar, wrap it as a menu-bar .app, install it in /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"
# Run the tests separately with: ./test.sh
swift build -c release
APP="build/Ember Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EmberBar "$APP/Contents/MacOS/EmberBar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ember Bar</string>
  <key>CFBundleDisplayName</key><string>Ember Bar</string>
  <key>CFBundleIdentifier</key><string>com.chesterdesmond.embarr</string>
  <key>CFBundleExecutable</key><string>EmberBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Ember Bar talks to your Ember mug over Bluetooth.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
pkill -x EmberBar 2>/dev/null && sleep 1 || true
rm -rf "/Applications/Ember Bar.app"
cp -R "$APP" "/Applications/Ember Bar.app"
# The Ember app holds the mug's only Bluetooth connection; quit it so Ember Bar can connect.
osascript -e 'quit app id "com.embertech.ios.Ember"' 2>/dev/null || true
open "/Applications/Ember Bar.app"
echo "Installed /Applications/Ember Bar.app"
