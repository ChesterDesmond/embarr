# Embarr

A menu-bar app for Ember mugs (built on Chester's Ember Cup 2), replacing Ember's own app.

Called Ember Bar before 1.4. The internal names stay (bundle ID `com.chesterdesmond.embarr`, executable `EmberBar`, the log, the
programs-file format), so settings, the paired mug and the Bluetooth permission carry over.

- **Menu bar:** drink temperature with the goal under it, on a cup tinted by what the heater is doing (orange
  heating or holding, blue cooling down to the goal, purple resting between pulses, teal heater off; it breathes
  while heating or cooling). Click for programs, a hold slider and a 20-minute chart.
- **Right-click** (or Control-click) the menu-bar icon for a menu: the mug's status and battery, Open Embarr,
  Settings…, heater on/off, Pause, Programs, Reconnect, Open at Login, About and Quit. The popover's "…" button has
  the app-level ones. SwiftUI's MenuBarExtra has no right-click, so `StatusMenu` catches it with a local event
  monitor on the status item's window.
- **Battery** is drawn in green (50% and up, or charging), yellow (21–49%) or red (20% and below), with the icon's
  fill following the charge (`BatteryLook.swift`).
- **Off the charger:** once the mug has been off the charger for a minute, a notification asks
  about the heater: Turn On / Leave Off when it is off, Keep On / Turn Off when it is on. Asked once each time
  the mug leaves the charger; putting it back removes the notification. A quick sip doesn't count. Settings >
  General turns it off. It doesn't wait for the mug to sense a drink: the mug reads "Empty" when a cool
  drink goes in with the heater off. It reads the battery characteristic's "on the charging base" byte (`ChargerWatch.swift`).
  It only works while the mug is awake and connected.
- **Open at Login** (Settings, or either menu) uses macOS's own Login Items list (`SMAppService`).
- **Programs:** "+ New program" in the popover (a hold or a glide; the editor also offers heater off); right-click a program to rename, edit
  or delete it; "Save as program" keeps the slider's hold. Clicking the running program again undoes that click
  (what was running, Turn on's memory, any pause, the glide clock); with nothing to undo it toggles the heater. The
  window's Programs page has Share > Export / Import programs (a JSON file of the programs only, read by
  `ProgramFile`). The slider is color-coded: blue cool, amber at 120 °F (the mark: the mug holds that and above by
  itself), red hot.
- **Choosing a mug:** with no mug yet, the popover lists "Mugs nearby" with Connect. Settings > Forget this mug picks
  another. Rename the mug from the pencil in the popover or the Settings page (stored on the mug; up to 14 characters).
- **On / Off / Pause** (popover and window): Turn off turns the heater off, Turn on goes back to the last program (a glide
  carries on where its clock says), Pause turns it off for 15 min, 30 min or an hour and then comes back by itself.
  While paused, Stay off ends the pause and keeps the heater off, and Resume goes back now.
  A pause that ended more than 30 min before Embarr could act on it (app quit or Mac asleep) stays off, with a
  notification saying so.
- **Window** (the window icon in the popover): full chart, preset and glide editor, LED color, units, heater tuning.
- **Below 48.9 °C / 120 °F** the mug won't hold a temperature by itself, so the app pulses the heater (target 0 = off,
  45 = on) and learns how far the drink keeps warming after each burst. This only runs while the Mac is connected.
  The firmware *accepts* targets down to 45 °C but still holds 48.89 (measured 2026-11-05 with coffee in it).
  Pulsed presets show an approximate average, since the drink swings a little around the goal.
- **Mug light:** an everyday color, optionally a color per preset, and a slow blink (6 s bright, 6 s dim) while the
  app is pulsing the heater toward the goal.
- **Bursts** are capped at 8 s: the mug's sensor lags the heater and then spikes (a 30 s burst read +14 °C a minute
  later), so the app waits for each burst's reading to peak before starting the next.
- **Glide:** a schedule of targets counted from when you pour (e.g. 45 → 41 → 37).
  A relaunch or a Bluetooth drop keeps the glide where it was. The app counts it as a new cup (glide restarts)
  only if it was out of touch for 15+ minutes and the drink came back at least 3 °C hotter, i.e. a refill.

Install or update: `./install.sh` (builds, installs to /Applications, relaunches).
Share a copy: `./package.sh` builds `dist/Ember-Bar-<VERSION>.zip` (Apple silicon and
Intel, macOS 14+, with `READ ME FIRST.txt` for the recipient); `package.sh --release` also uploads it as a release on
the private GitHub repo. It is signed ad hoc, not notarized, so the recipient clicks "Open Anyway" once per version (and macOS may ask
for Bluetooth permission again after an update, since each ad-hoc build counts as a new app).
Check the layout without clicking the menu bar: `EMBERBAR_SNAPSHOT=/tmp/snap "build/Embarr.app/Contents/MacOS/EmberBar"`
writes PNGs of the popover, the window pages and a highlighted button (it never touches the mug).
Tests: `./test.sh` (plain `swift test` can't find swift-testing's macro plugin with only
Command Line Tools installed; see ~/.claude/papercuts.md).
Log: `~/Library/Logs/EmberBar.log`. One-off CLI: `./set-temp.sh 50`.

Only one device can talk to the mug at a time: quit Ember's app (Mac or phone) or Embarr can't connect.
Protocol notes are in `Sources/EmberCore/Protocol.swift`.

## License

MIT, © 2026 ChesterDesmond: see `LICENSE`. Not made by or affiliated with Ember Technologies, Inc.; Ember is their
trademark.
