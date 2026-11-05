# Ember Bar

A menu-bar app for Chester's Ember mug (Ember Cup 2), replacing Ember's own app.

- **Menu bar:** coffee temperature with the goal under it, on a cup tinted by what the heater is doing (orange
  heating or holding, blue cooling down to the goal, purple resting between pulses, teal heater off; it breathes
  while heating or cooling). Click for presets, a hold slider and a 20-minute chart.
- **Window** (the window icon in the popover): full chart, preset and glide editor, LED color, units, heater tuning.
- **Below 48.9 °C / 120 °F** the mug won't hold a temperature by itself, so the app pulses the heater (target 0 = off,
  45 = on) and learns how far the coffee keeps warming after each burst. This only runs while the Mac is connected.
  The firmware *accepts* targets down to 45 °C but still holds 48.89 (measured 2026-11-05 with coffee in it).
  Pulsed presets show an approximate average, since the coffee swings a little around the goal.
- **Mug light:** an everyday color, optionally a color per preset, and a slow blink (6 s bright, 6 s dim) while the
  app is pulsing the heater toward the goal.
- **Bursts** are capped at 8 s: the mug's sensor lags the heater and then spikes (a 30 s burst read +14 °C a minute
  later), so the app waits for each burst's reading to peak before starting the next.
- **Glide:** a schedule of targets counted from when you pour (e.g. 45 → 41 → 37).
  A relaunch or a Bluetooth drop keeps the glide where it was. The app counts it as a new cup (glide restarts)
  only if it was out of touch for 15+ minutes and the coffee came back at least 3 °C hotter, i.e. a refill.

Install or update: `./install.sh` (builds, installs to /Applications, relaunches).
Tests: `./test.sh` (plain `swift test` can't find swift-testing's macro plugin with only
Command Line Tools installed; see ~/.claude/papercuts.md).
Log: `~/Library/Logs/EmberBar.log`. One-off CLI: `./set-temp.sh 50`.

Only one device can talk to the mug at a time: quit Ember's app (Mac or phone) or Ember Bar can't connect.
Protocol notes are in `Sources/EmberCore/Protocol.swift`.
