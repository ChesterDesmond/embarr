#!/bin/bash
# Build Embarr, wrap it as a menu-bar .app, install it in /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"
# Run the tests separately with: ./test.sh
swift build -c release
scripts/bundle.sh .build/release/EmberBar build
APP="build/Embarr.app"
pkill -x EmberBar 2>/dev/null && sleep 1 || true
rm -rf "/Applications/Embarr.app" "/Applications/Ember Bar.app"   # the app was called Ember Bar before 1.4
cp -R "$APP" "/Applications/Embarr.app"
# The Ember app holds the mug's only Bluetooth connection; quit it so Embarr can connect.
osascript -e 'quit app id "com.embertech.ios.Ember"' 2>/dev/null || true
open "/Applications/Embarr.app"
echo "Installed /Applications/Embarr.app"
