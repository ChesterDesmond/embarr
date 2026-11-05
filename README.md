# Ember Bar

A menu-bar app for Chester's Ember mug (Ember Cup 2), replacing Ember's own app.

- **Menu bar:** coffee temperature; click for presets, a hold slider and a 20-minute chart.
- **Window** (the window icon in the popover): full chart, preset and glide editor, LED color, units, heater tuning.
- **Below 45 °C / 113 °F** the mug's firmware won't hold a target, so the app pulses the heater (target 0 = off,
  45 = on) and learns how far the coffee keeps warming after each burst. This only runs while the Mac is connected.
- **Glide:** a schedule of targets counted from when you pour (e.g. 45 → 41 → 37).

Install or update: `./install.sh` (builds, installs to /Applications, relaunches).
Tests: `swift test` (run twice if the first build says only "fatalError"; see ~/.claude/papercuts.md).
Log: `~/Library/Logs/EmberBar.log`. One-off CLI: `./set-temp.sh 45`.

Only one device can talk to the mug at a time: quit Ember's app (Mac or phone) or Ember Bar can't connect.
Protocol notes are in `Sources/EmberCore/Protocol.swift`.
