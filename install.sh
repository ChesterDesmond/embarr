#!/bin/bash
# Build Ember Bar, wrap it as a menu-bar .app, install it in /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"
# Run the tests separately with: ./test.sh
swift build -c release
scripts/bundle.sh .build/release/EmberBar build
APP="build/Ember Bar.app"
pkill -x EmberBar 2>/dev/null && sleep 1 || true
rm -rf "/Applications/Ember Bar.app"
cp -R "$APP" "/Applications/Ember Bar.app"
# The Ember app holds the mug's only Bluetooth connection; quit it so Ember Bar can connect.
osascript -e 'quit app id "com.embertech.ios.Ember"' 2>/dev/null || true
open "/Applications/Ember Bar.app"
echo "Installed /Applications/Ember Bar.app"
