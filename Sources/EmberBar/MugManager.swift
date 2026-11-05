import CoreBluetooth
import EmberCore
import Foundation
import SwiftUI
import UserNotifications

enum WindowPage: Hashable { case now, programs, mug }

struct Sample: Identifiable {
    let id = UUID()
    let time: Date
    let temp: Double
    let goal: Double?
    let heating: Bool
}

@MainActor
final class MugManager: NSObject, ObservableObject {
    enum Link: Equatable {
        case bluetoothOff, bluetoothDenied, scanning, connecting, waitingForMug, connected

        /// Bluetooth isn't powered on. Denied permission is told apart from switched off because its fix is in System
        /// Settings, not Control Center. Anything else (still starting up, resetting, or the permission prompt still
        /// open) is not something to fix yet, so it reads as still looking.
        init(unavailable state: CBManagerState) {
            switch state {
            case .unauthorized: self = .bluetoothDenied
            case .poweredOff: self = .bluetoothOff
            default: self = .scanning
            }
        }

        /// Bluetooth itself is unusable, so there is no mug to look for.
        var bluetoothUnavailable: Bool { self == .bluetoothOff || self == .bluetoothDenied }

        var label: String {
            switch self {
            case .bluetoothOff: "Bluetooth is off"
            case .bluetoothDenied: "Bluetooth not allowed"
            case .scanning: "Looking for the mug…"
            case .connecting: "Connecting…"
            case .waitingForMug: "Mug busy: quit the Ember app"
            case .connected: "Connected"
            }
        }
    }

    // Live readings
    @Published var link: Link = .scanning {
        didSet {
            guard link != oldValue else { return }
            log("link: \(link.label)")
            updateIconAnimation()
            // The "not finding your mug" minute counts only time spent looking: while Bluetooth is off or not
            // allowed it is cleared, and it starts over once Bluetooth is usable again.
            if link == .connected || link.bluetoothUnavailable { linkDownSince = nil; mugMissing = false }
            else if linkDownSince == nil { linkDownSince = Date() }
        }
    }
    @Published var name = "Ember mug"
    @Published var temp: Double?
    @Published var mugTarget: Double?
    @Published var state: LiquidState = .unknown
    @Published var battery: EmberCodec.Battery?
    @Published var level: Int?
    @Published var firmware: String?
    @Published var led: EmberCodec.RGB?
    @Published var goal: Double?
    @Published var pulsing = false
    @Published var history: [Sample] = []

    // Settings (persisted)
    @Published var mode: Mode { didSet { modeChanged() } }
    @Published var activePresetID: UUID? { didSet { save() } }
    @Published var presets: [Preset] { didSet { save() } }
    @Published var unit: TempUnit { didSet { save() } }
    @Published var controller: HeaterController
    /// The mug's everyday light color, used whenever the active preset has no color of its own.
    @Published var homeLight: EmberCodec.RGB? { didSet { save() } }
    /// Slowly blink the mug's light while Ember Bar is cycling the heater (pulsed holds and glides).
    @Published var blinkWhileCycling: Bool { didSet { save() } }
    /// What the power button and Pause go back to, and when a pause ends.
    @Published private(set) var power: PowerMemory { didSet { save() } }
    /// Which page the main window shows, and a program the window should open in its editor (set from the popover).
    @Published var windowPage: WindowPage = .now
    @Published var editRequest: Preset?
    /// Drives the menu-bar icon's breathing. Kept off MugManager's own @Published values so only the icon redraws.
    let iconClock = IconClock()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [String: CBCharacteristic] = [:]
    private var pollTimer: Timer?
    private var waitTimer: Timer?
    private var tick = 0
    private var lastWrite: (value: Double, at: Date)?
    private var verifying: (value: Double, retried: Bool)?
    private var warnedBattery = false
    private var lastLight: EmberCodec.RGB?
    private var loading = true
    /// Set while the power row (Off, On, Pause, a pause running out) changes the mode, as opposed to the user
    /// choosing a program: the glide clock keeps running and the remembered program stays.
    private var powerChange = false
    private var powerTimer: Timer?

    private let defaults = UserDefaults.standard
    /// What a fresh install starts on: "Hot sip", 45 C / 113 F.
    private static let firstRunMode = Mode.hold(45)

    /// Mugs heard while choosing one ("Mugs nearby"), in the order they showed up. Empty once a mug is paired.
    @Published private(set) var nearby: [NearbyMugs.Mug] = []
    /// Whether this Mac has a mug of its own. Without one, the app lists nearby mugs and waits for Connect, so a
    /// household with two mugs never grabs the wrong one.
    @Published private(set) var hasPairedMug: Bool
    /// Set when the mug refused a setting or a new name (a mug reset since it was last set up in Ember's app refuses
    /// writes). Cleared on the next connect.
    @Published var mugProblem: String?
    /// True once this Mac's mug has been out of reach for a minute (asleep mugs drop the link briefly; this is longer),
    /// so the popover can suggest what to try.
    @Published private(set) var mugMissing = false
    private var linkDownSince: Date? = Date()
    /// Writes refused in a row. One can be a Bluetooth hiccup; several mean the mug won't take settings.
    private var refusedWrites = 0
    private var nearbyMugs = NearbyMugs()
    private var discovered: [UUID: CBPeripheral] = [:]

    /// UserDefaults key holding this Mac's mug (its CoreBluetooth identifier).
    private static let pairedKey = "peripheral"
    private var pairedID: UUID? { defaults.string(forKey: Self.pairedKey).flatMap(UUID.init(uuidString:)) }

    /// `live: false` makes a copy that never touches Bluetooth, timers or notifications (the snapshot tool).
    init(live: Bool = true) {
        let d = UserDefaults.standard
        func load<T: Decodable>(_ key: String) -> T? {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        let savedMode: Mode = load("mode") ?? Self.firstRunMode
        mode = savedMode
        var saved: [Preset] = load("presets") ?? Preset.defaults
        // "Mug floor" (45 C) was renamed once it turned out the mug never holds that low by itself.
        for i in saved.indices where saved[i].name == "Mug floor" && saved[i].mode == .hold(45) { saved[i].name = "Hot sip" }
        presets = saved
        let savedPresetID: UUID? = load("activePresetID")
        activePresetID = savedPresetID
        unit = load("unit") ?? .fahrenheit
        controller = load("controller") ?? HeaterController()
        homeLight = load("homeLight")
        blinkWhileCycling = load("blinkWhileCycling") ?? true
        var memory: PowerMemory = load("power") ?? PowerMemory()
        if memory.resumeMode == nil, savedMode != .off { memory.chose(savedMode, presetID: savedPresetID) }
        power = memory
        hasPairedMug = d.string(forKey: Self.pairedKey) != nil
        super.init()
        loading = false
        guard live else { return }
        powerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resumeIfPauseOver()
                self.publishNearby()  // drops mugs that went quiet
                let missing = self.hasPairedMug && !self.link.bluetoothUnavailable && (self.linkDownSince.map { Date().timeIntervalSince($0) > 60 } ?? false)
                if missing != self.mugMissing { self.mugMissing = missing }
            }
        }
        central = CBCentralManager(delegate: self, queue: .main)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Settings

    private func save() {
        guard !loading else { return }
        func put<T: Encodable>(_ v: T, _ key: String) {
            if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: key) }
        }
        put(mode, "mode")
        put(presets, "presets")
        put(activePresetID, "activePresetID")
        put(unit, "unit")
        put(controller, "controller")
        put(homeLight, "homeLight")
        put(blinkWhileCycling, "blinkWhileCycling")
        put(power, "power")
    }

    var activePreset: Preset? {
        presets.first { $0.id == activePresetID && $0.mode == mode }
    }

    var phase: HeaterPhase {
        HeaterPhase(connected: link == .connected, state: state, temp: temp, goal: goal, pulsing: pulsing)
    }

    /// Whether the menu-bar icon should be breathing right now.
    private var iconAnimates: Bool { phase == .heating || phase == .coolingToGoal }

    private func updateIconAnimation() { iconClock.running = iconAnimates }

    private func modeChanged() {
        guard !loading else { return }
        // Turning the heater off (Off, Pause, "Just let it cool") never moves the pour time, so On picks a glide up
        // where the clock says.
        controller.resetForNewMode(now: Date(), keepCupClock: powerChange || mode == .off)
        if !powerChange { power.chose(mode, presetID: activePresetID) }
        save()
        runController()
        updateLight()
        updateIconAnimation()
    }

    func apply(_ preset: Preset) {
        activePresetID = preset.id
        mode = preset.mode
    }

    // MARK: Power: on, off, pause

    var isOn: Bool { mode != .off }

    /// When the current pause ends, or nil when not paused.
    var pausedUntil: Date? { power.isPaused(now: Date()) ? power.pausedUntil : nil }

    /// "Paused until 3:45 PM", or nil when not paused.
    var pausedText: String? { pausedUntil.map { "Paused until \($0.formatted(date: .omitted, time: .shortened))" } }

    func turnOff() {
        guard isOn else { return }
        switchOffRemembering()
        log("power: off")
    }

    func turnOn() {
        let back = power.turnOn()
        setByPower(back.mode, presetID: back.presetID)
        log("power: on, \(modeDescription(mode))")
    }

    /// Heater off for `minutes`, then back to the current program by itself.
    func pause(minutes: Double) {
        guard isOn else { return }
        switchOffRemembering(pauseUntil: Date().addingTimeInterval(minutes * 60))
        log("power: paused \(Int(minutes)) min")
    }

    /// The power button during a pause: end the pause and keep the heater off. Turn on still knows the program.
    func stayOff() {
        power.endPause()
        log("power: pause ended early, staying off")
    }

    private func resumeIfPauseOver() {
        // Checked first so the usual case (not paused) doesn't touch `power`, whose didSet would save and redraw.
        guard power.pausedUntil != nil, !power.isPaused(now: Date()) else { return }
        guard let back = power.dueResume(now: Date()) else {
            log("power: pause ended long ago, staying off")
            notify("Heater still off", "Your pause ended while Ember Bar was away from the mug. Click Turn on to go back to your program.")
            return
        }
        setByPower(back.mode, presetID: back.presetID)
        log("power: pause over, back to \(modeDescription(mode))")
    }

    /// Off or Pause: remember what was running so On (or the end of the pause) goes back to it.
    private func switchOffRemembering(pauseUntil: Date? = nil) {
        power.chose(mode, presetID: activePresetID)
        if let until = pauseUntil { power.pause(until: until) }
        setByPower(.off, presetID: nil)
    }

    private func setByPower(_ mode: Mode, presetID: UUID?) {
        let (mode, presetID) = mode == .off ? (mode, presetID) : PowerMemory.current((mode, presetID), in: presets)
        powerChange = true
        defer { powerChange = false }
        activePresetID = presetID
        self.mode = mode
    }

    func setHold(celsius: Double) {
        activePresetID = nil
        mode = .hold((celsius * 10).rounded() / 10)
    }

    // MARK: Programs (presets) from the popover

    /// Saves `mode` as a new program. When it is what's running now, it becomes the active program too, so the tile
    /// lights up and Turn on comes back to it, without restarting anything.
    func addProgram(name: String, mode newMode: Mode) {
        let p = Preset(name: Preset.cleanName(name) ?? "My program", mode: newMode)
        presets.append(p)
        if newMode == mode {
            activePresetID = p.id
            power.chose(mode, presetID: p.id)
        }
    }

    func renameProgram(_ id: UUID, to name: String) {
        guard let clean = Preset.cleanName(name), let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = clean
    }

    /// Removes a program. If it was the one running, the mug keeps running its settings, no longer tied to a tile,
    /// and goes back to the everyday light color.
    func deleteProgram(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
        updateLight()
    }

    /// Asks the main window to show a page, and optionally open the program editor on `preset` (a new one or an
    /// existing one). The popover can't host the editor itself: a sheet on a menu-bar panel closes with the panel.
    func openInWindow(page: WindowPage, editing preset: Preset? = nil) {
        windowPage = page
        editRequest = preset
    }

    // MARK: Mug name

    /// Renames the mug itself (stored on the mug, so Ember's own app sees it too). Returns why it can't, or nil once
    /// the name is sent; a refusal from the mug arrives later in `mugProblem`.
    func renameMug(_ newName: String) -> String? {
        guard let data = EmberCodec.encodeName(newName) else { return EmberCodec.nameHint }
        guard link == .connected, let p = peripheral, let c = chars[EmberUUID.mugName] else { return "Connect to the mug first." }
        mugProblem = nil
        p.writeValue(data, for: c, type: .withResponse)
        log("rename mug: \(newName)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let c = self.chars[EmberUUID.mugName] else { return }
                self.peripheral?.readValue(for: c)
            }
        }
        return nil
    }

    // MARK: Choosing a mug

    /// Connects to a mug from "Mugs nearby" and makes it this Mac's mug.
    func pair(_ id: UUID) {
        guard let p = discovered[id] else { return }
        defaults.set(id.uuidString, forKey: Self.pairedKey)
        hasPairedMug = true
        nearbyMugs.clear()
        nearby = []
        discovered = [:]
        linkDownSince = Date()  // the minute before "not finding your mug" starts now, not at launch
        log("pair: \(p.name ?? id.uuidString)")
        connect(p)
    }

    /// Lets go of this mug (heater off if Ember Bar was pulsing it, light back to steady) and goes back to listing
    /// mugs nearby. What belonged to that mug goes too: its light color and the learned overshoot.
    func forgetMug() {
        releaseMug()
        defaults.removeObject(forKey: Self.pairedKey)
        hasPairedMug = false
        let old = peripheral
        peripheral = nil  // from here on, callbacks from the old mug are ignored (see `isCurrent`)
        chars = [:]
        pollTimer?.invalidate()
        waitTimer?.invalidate()  // a pending "mug busy" from the old connect attempt no longer applies
        dropReadings()
        battery = nil; level = nil; firmware = nil; led = nil; mugTarget = nil; goal = nil; pulsing = false
        homeLight = nil
        resetLearning()
        mugProblem = nil
        refusedWrites = 0
        name = "Ember mug"
        log("forget mug")
        // Give the heater-off write time to reach the mug before letting go of the link.
        if let old {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    // Connect on this same mug in the meantime made it current again: keep that link.
                    guard let self, self.peripheral !== old else { return }
                    self.central.cancelPeripheralConnection(old)
                }
            }
        }
        startScan()
    }

    /// Bluetooth callbacks can arrive from a mug that was just forgotten; only the current one counts.
    private func isCurrent(_ p: CBPeripheral) -> Bool { p === peripheral }

    private func publishNearby() {
        guard !hasPairedMug else { return }
        // Only redraw when a row appears, goes or is renamed: signal strength alone isn't shown.
        let list = nearbyMugs.list(now: Date())
        guard list.map(\.id) != nearby.map(\.id) || list.map(\.name) != nearby.map(\.name) else { return }
        nearby = list
    }

    func resetLearning() {
        controller.overshoot = HeaterController().overshoot
        save()
    }

    // MARK: Connection

    func reconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        chars = [:]
        dropReadings()
        startScan()
    }

    private func startScan() {
        guard central.state == .poweredOn else { link = Link(unavailable: central.state); return }
        if let idString = defaults.string(forKey: Self.pairedKey), let id = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }
        link = .scanning
        // Duplicates on: signal strength keeps updating, and mugs that go quiet drop off the list.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: !hasPairedMug])
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        link = .connecting
        if let n = p.name { name = n }
        central.connect(p)
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.link == .connecting { self?.link = .waitingForMug }
            }
        }
    }

    /// The link is gone: forget readings from before the gap so the first controller run after it waits for fresh
    /// ones, and let the controller re-check whether the cup was replaced meanwhile.
    private func dropReadings() {
        lastLight = nil
        temp = nil
        state = .unknown
        controller.lostContact()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        guard let p = peripheral, link == .connected else { return }
        tick += 1
        for uuid in [EmberUUID.currentTemp, EmberUUID.liquidState, EmberUUID.targetTemp] {
            if let c = chars[uuid] { p.readValue(for: c) }
        }
        if tick % 10 == 1 {
            for uuid in [EmberUUID.battery, EmberUUID.liquidLevel] {
                if let c = chars[uuid] { p.readValue(for: c) }
            }
        }
        runController()
        updateLight()
        updateIconAnimation()
        if let t = temp, tick % 20 == 0 {
            log(String(format: "sample coffee %.2f state %@ mug-target %.2f goal %@ pulsing %@ overshoot %.2f", t, state.label,
                       mugTarget ?? -1, goal.map { String(format: "%.2f", $0) } ?? "none", pulsing ? "yes" : "no", controller.overshoot))
        }
        if let t = temp, tick % 2 == 0 {
            history.append(Sample(time: Date(), temp: t, goal: goal, heating: pulsing || state == .heating))
            let cutoff = Date().addingTimeInterval(-4 * 3600)
            if let first = history.first, first.time < cutoff { history.removeAll { $0.time < cutoff } }
        }
    }

    // MARK: Control

    private func runController() {
        guard link == .connected else { return }
        let learned = controller.overshoot
        let out = controller.update(now: Date(), temp: temp, state: state, mode: mode)
        // Save what learned, and the pour time, so a relaunch mid-cup picks the glide up where it was.
        // Also once a minute, so a relaunch knows how long Ember Bar was away from the mug (`lastSeen`).
        if controller.overshoot != learned || out.events.contains(.filled) || out.events.contains(.emptied)
            || tick % 20 == 0 { save() }
        goal = out.goal
        pulsing = out.pulsing
        for e in out.events { handle(e) }
        guard let want = out.heaterTarget else { return }
        let recentlyWritten = lastWrite.map { abs($0.value - want) < 0.01 && Date().timeIntervalSince($0.at) < 10 } ?? false
        let mugAgrees = mugTarget.map { abs($0 - want) < 0.05 } ?? false
        if !mugAgrees && !recentlyWritten { writeTarget(want) }
    }

    private func writeTarget(_ celsius: Double, retried: Bool = false) {
        guard let p = peripheral, let c = chars[EmberUUID.targetTemp] else { return }
        p.writeValue(EmberCodec.encodeTemp(celsius), for: c, type: .withResponse)
        log(String(format: "write target %.2f (coffee %.2f, state %@, goal %@)", celsius, temp ?? -1, state.label,
                   goal.map { String(format: "%.2f", $0) } ?? "none"))
        lastWrite = (celsius, Date())
        verifying = (celsius, retried)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let c = self.chars[EmberUUID.targetTemp] else { return }
                self.peripheral?.readValue(for: c)
            }
        }
    }

    /// The firmware sometimes refuses a low target written straight from its 48.88 C default, but keeps it
    /// when stepped through an in-range value (measured 2026-11-05).
    private func verifyTarget(_ read: Double) {
        guard let v = verifying else { return }
        verifying = nil
        guard abs(read - v.value) >= 0.05, v.value > 0, !v.retried else { return }
        writeTarget(52)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.writeTarget(v.value, retried: true) }
        }
    }

    /// Sets the mug's everyday light color (the Mug page's color picker).
    func setHomeLight(_ rgb: EmberCodec.RGB) {
        homeLight = rgb
        updateLight()
    }

    /// The light the mug should show when not on the dim half of a blink. Never `led`, which may hold the dim half.
    private var lightBase: EmberCodec.RGB? { activePreset?.light ?? homeLight }

    /// Puts the active preset's color (or the everyday one) on the mug. Re-run every poll (3 s). The blink half is read off the clock and lasts 6 s, twice the poll, so neither
    /// timer jitter nor the extra polls push events trigger can skip a half. It blinks only while the current
    /// goal is one Ember Bar pulses, not during a glide step the mug holds by itself.
    private func updateLight() {
        guard link == .connected, let base = lightBase else { return }
        let blinking = blinkWhileCycling && state.hasLiquid && goal.map(MugLimits.needsPulsing) == true
        let want = MugLight.color(base: base, blinking: blinking, tick: Int(Date().timeIntervalSince1970 / 6))
        guard want != lastLight else { return }
        writeLED(want)
    }

    private func writeLED(_ rgb: EmberCodec.RGB) {
        guard let p = peripheral, let c = chars[EmberUUID.ledColor] else { return }
        p.writeValue(EmberCodec.encodeLED(rgb), for: c, type: .withResponse)
        lastLight = rgb
    }

    /// Called on quit: never leave the heater on when the app was pulsing below what the mug holds by itself,
    /// and never leave the light parked on its dim blink.
    func prepareForQuit() {
        releaseMug()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    /// Leaves the mug safe to walk away from: heater off if Ember Bar was pulsing it below what the mug holds by
    /// itself, and the light on its steady color rather than the dim half of a blink. The writes are queued; the caller
    /// keeps the link open long enough for them to land.
    private func releaseMug() {
        guard let p = peripheral else { return }
        if let base = lightBase, lastLight != base, let c = chars[EmberUUID.ledColor] {
            p.writeValue(EmberCodec.encodeLED(base), for: c, type: .withResponse)
        }
        if case let g? = goal, MugLimits.needsPulsing(g), let c = chars[EmberUUID.targetTemp] {
            p.writeValue(EmberCodec.encodeTemp(MugLimits.off), for: c, type: .withResponse)
        }
    }

    // MARK: Log (~/Library/Logs/EmberBar.log)

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/EmberBar.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    func log(_ line: String) {
        let text = "\(Self.stamp.string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: Self.logURL)
        }
    }

    // MARK: Notifications

    private func handle(_ e: ControllerEvent) {
        log("event: \(e)")
        switch e {
        case .ready(let target):
            notify("Coffee is ready", "It's at \(unit.format(target))\(unit.rawValue).")
        case .filled, .emptied:
            break
        }
    }

    private func checkBattery() {
        guard let b = battery else { return }
        if b.charging || b.percent > 20 { warnedBattery = false; return }
        if b.percent <= 15 && !warnedBattery {
            warnedBattery = true
            notify("Mug battery low", "\(b.percent)% left. Put it on the coaster.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension MugManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn { startScan() } else {
                pollTimer?.invalidate()
                link = Link(unavailable: central.state)
                dropReadings()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let ember = services.contains { EmberUUID.isEmberService($0.uuidString) }
        MainActor.assumeIsolated {
            if let id = pairedID {
                // Looking for this Mac's own mug (it may have been renamed, so match by identity, not name).
                if p.identifier == id, link == .scanning { connect(p) }
                return
            }
            nearbyMugs.saw(id: p.identifier, name: advName, rssi: rssi.intValue, at: Date(), advertisesEmberService: ember)
            if nearbyMugs.list(now: Date()).contains(where: { $0.id == p.identifier }) { discovered[p.identifier] = p }
            publishNearby()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            waitTimer?.invalidate()
            defaults.set(p.identifier.uuidString, forKey: Self.pairedKey)
            p.discoverServices([CBUUID(string: EmberUUID.service)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if isCurrent(p) { reconnectSoon() } }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if isCurrent(p) { reconnectSoon() } }
    }

    private func reconnectSoon() {
        pollTimer?.invalidate()
        chars = [:]
        dropReadings()
        link = .scanning
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                // Something else (Connect on another mug, Forget) may have moved on during the wait.
                // Bluetooth may also be resetting (shown as still looking): connecting then is an API misuse.
                guard let self, self.link == .scanning, self.central.state == .poweredOn else { return }
                if let p = self.peripheral { self.connect(p) } else { self.startScan() }
            }
        }
    }
}

extension MugManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            mugProblem = nil
            for c in s.characteristics ?? [] {
                chars[c.uuid.uuidString.uppercased()] = c
                if c.uuid.uuidString.uppercased() == EmberUUID.pushEvents { p.setNotifyValue(true, for: c) }
            }
            for uuid in [EmberUUID.firmware, EmberUUID.ledColor, EmberUUID.battery, EmberUUID.liquidLevel, EmberUUID.mugName] {
                if let c = chars[uuid] { p.readValue(for: c) }
            }
            link = .connected
            startPolling()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        let uuid = c.uuid.uuidString.uppercased()
        let reason = error?.localizedDescription
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            guard let reason else { refusedWrites = 0; return }
            refusedWrites += 1
            if refusedWrites == 1 || refusedWrites % 50 == 0 { log("write refused (\(uuid)), \(refusedWrites) in a row: \(reason)") }
            let setUp = "If it was reset, set it up once in Ember's phone app, then quit that app."
            if uuid == EmberUUID.mugName {
                mugProblem = "The mug didn't accept the new name. " + setUp
            } else if refusedWrites >= 3, mugProblem == nil {
                mugProblem = "The mug isn't accepting Ember Bar's settings. " + setUp
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        let uuid = c.uuid.uuidString.uppercased()
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            switch uuid {
            case EmberUUID.currentTemp: temp = EmberCodec.decodeTemp(data)
            case EmberUUID.targetTemp:
                mugTarget = EmberCodec.decodeTemp(data)
                if let t = mugTarget { verifyTarget(t) }
            case EmberUUID.liquidState:
                state = EmberCodec.decodeLiquidState(data)
                if state == .unknown { log("unrecognized liquid state byte \(data.first ?? 0)") }
            case EmberUUID.battery: battery = EmberCodec.decodeBattery(data); checkBattery()
            case EmberUUID.liquidLevel: level = data.first.map(Int.init)
            case EmberUUID.firmware: firmware = EmberCodec.decodeFirmware(data)
            case EmberUUID.mugName: if let n = EmberCodec.decodeName(data) { name = n }
            case EmberUUID.ledColor:
                led = EmberCodec.decodeLED(data)
                if homeLight == nil, let l = led { homeLight = l }  // first connect: adopt the mug's own color
            case EmberUUID.pushEvents: poll()
            default: break
            }
        }
    }
}

/// Ticks about 6 times a second while the menu-bar icon breathes, and not at all otherwise.
@MainActor
final class IconClock: ObservableObject {
    @Published private(set) var frame = 0
    private var timer: Timer?

    var running = false {
        didSet {
            guard running != oldValue else { return }
            timer?.invalidate()
            timer = nil
            if running {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.frame &+= 1 }
                }
            }
        }
    }
}
