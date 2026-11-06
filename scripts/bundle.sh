#!/bin/bash
# Wraps a built EmberBar binary as "Ember Bar.app" with its icon, and signs it ad hoc.
# Usage: scripts/bundle.sh <binary> <out-dir>   (writes <out-dir>/Ember Bar.app)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:?usage: bundle.sh <binary> <out-dir>}"; OUT="${2:?usage: bundle.sh <binary> <out-dir>}"
VERSION="$(cat "$ROOT/VERSION")"
APP="$OUT/Ember Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EmberBar"

# Icon: drawn by scripts/make-icon.swift, cached in .build so it is only drawn once.
ICNS="$ROOT/.build/EmberBar.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]; then
  rm -rf "$ROOT/.build/EmberBar.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/.build/EmberBar.iconset"
  iconutil -c icns "$ROOT/.build/EmberBar.iconset" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/EmberBar.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ember Bar</string>
  <key>CFBundleDisplayName</key><string>Ember Bar</string>
  <key>CFBundleIdentifier</key><string>com.chesterdesmond.embarr</string>
  <key>CFBundleExecutable</key><string>EmberBar</string>
  <key>CFBundleIconFile</key><string>EmberBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 ChesterDesmond. MIT License. Not affiliated with Ember Technologies, Inc.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Ember Bar talks to your Ember mug over Bluetooth.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
