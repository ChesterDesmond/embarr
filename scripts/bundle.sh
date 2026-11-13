#!/bin/bash
# Wraps a built EmberBar binary as "Embarr.app" with its icon, and signs it: with the "Embarr" certificate when this
# Mac has it (scripts/make-signing-identity.sh), else ad hoc. The certificate gives every build the same designated
# requirement, so macOS keeps the Bluetooth permission across updates and the in-app updater can check that an
# update was signed by the same certificate. An ad-hoc build can't update itself.
# Usage: scripts/bundle.sh <binary> <out-dir>   (writes <out-dir>/Embarr.app)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:?usage: bundle.sh <binary> <out-dir>}"; OUT="${2:?usage: bundle.sh <binary> <out-dir>}"
VERSION="$(cat "$ROOT/VERSION")"
APP="$OUT/Embarr.app"
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
  <key>CFBundleName</key><string>Embarr</string>
  <key>CFBundleDisplayName</key><string>Embarr</string>
  <key>CFBundleIdentifier</key><string>com.chesterdesmond.embarr</string>
  <key>CFBundleExecutable</key><string>EmberBar</string>
  <key>CFBundleIconFile</key><string>EmberBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 ChesterDesmond. MIT License. Not affiliated with Ember Technologies, Inc.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Embarr talks to your Ember mug over Bluetooth.</string>
</dict></plist>
PLIST
KC="$HOME/Library/Keychains/embarr-signing.keychain-db"; PWFILE="$HOME/.config/embarr-signing/password"
if [ -f "$KC" ] && [ -f "$PWFILE" ]; then
  security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
  HASH="$(security find-identity -p codesigning "$KC" | awk '/"Embarr"/ {print $2; exit}')"
  codesign --force --sign "$HASH" --keychain "$KC" "$APP"
else
  echo "No Embarr signing certificate on this Mac: signing ad hoc (this build can't install updates)." >&2
  codesign --force --sign - "$APP"
fi
