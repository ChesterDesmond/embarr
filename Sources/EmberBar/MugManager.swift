import CoreBluetooth
import EmberCore
import Foundation
import SwiftUI
import UserNotifications

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
        case bluetoothOff, scanning, connecting, waitingForMug, connected

        var label: String {
            switch self {
            case .bluetoothOff: "Bluetooth is off"
            case .scanning: "Looking for the mug…"
            case .connecting: "Connecting…"
            case .waitingForMug: "Mug busy: quit the Ember app"
            case .connected: "Connected"
            }
        }
    }

    // Live readings
    @Published var link: Link = .scanning { didSet { if link != oldValue { log("link: \(link.label)") } } }
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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [String: CBCharacteristic] = [:]
    private var pollTimer: Timer?
    private var waitTimer: Timer?
    private var tick = 0
    private var lastWrite: (value: Double, at: Date)?
    private var verifying: (value: Double, retried: Bool)?
    private var warnedBattery = false
    private var loading = true

    private let defaults = UserDefaults.standard

    override init() {
        let d = UserDefaults.standard
        func load<T: Decodable>(_ key: String) -> T? {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        mode = load("mode") ?? .hold(MugLimits.floor)
        presets = load("presets") ?? Preset.defaults
        activePresetID = load("activePresetID")
        unit = load("unit") ?? .fahrenheit
        controller = load("controller") ?? HeaterController()
        super.init()
        loading = false
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
    }

    private func modeChanged() {
        guard !loading else { return }
        controller.resetForNewMode(now: Date())
        save()
        runController()
    }

    func apply(_ preset: Preset) {
        activePresetID = preset.id
        mode = preset.mode
    }

    func setHold(celsius: Double) {
        activePresetID = nil
        mode = .hold((celsius * 10).rounded() / 10)
    }

    func saveCurrentAsPreset(named name: String) {
        let p = Preset(name: name, mode: mode)
        presets.append(p)
        activePresetID = p.id
    }

    func resetLearning() {
        controller.overshoot = 1.0
        save()
    }

    // MARK: Connection

    func reconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        chars = [:]
        startScan()
    }

    private func startScan() {
        guard central.state == .poweredOn else { link = .bluetoothOff; return }
        if let idString = defaults.string(forKey: "peripheral"), let id = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }
        link = .scanning
        central.scanForPeripherals(withServices: nil)
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
        if controller.overshoot != learned { save() }
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

    /// The firmware sometimes refuses a low target written straight from the 48.88 C floor, but keeps it
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

    func setLED(_ rgb: EmberCodec.RGB) {
        guard let p = peripheral, let c = chars[EmberUUID.ledColor] else { return }
        p.writeValue(EmberCodec.encodeLED(rgb), for: c, type: .withResponse)
        led = rgb
    }

    /// Called on quit: never leave the mug parked at the 45 C floor when the app was pulsing below it.
    func prepareForQuit() {
        guard case let g? = goal, g < MugLimits.floor, let p = peripheral, let c = chars[EmberUUID.targetTemp] else { return }
        p.writeValue(EmberCodec.encodeTemp(MugLimits.off), for: c, type: .withResponse)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
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
            notify("Coffee is ready", "It's down to \(unit.format(target)) \(unit.rawValue).")
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
            if central.state == .poweredOn { startScan() } else { link = .bluetoothOff }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard advName.hasPrefix("Ember") else { return }
        MainActor.assumeIsolated {
            name = advName
            connect(p)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            waitTimer?.invalidate()
            defaults.set(p.identifier.uuidString, forKey: "peripheral")
            p.discoverServices([CBUUID(string: EmberUUID.service)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { reconnectSoon() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { reconnectSoon() }
    }

    private func reconnectSoon() {
        pollTimer?.invalidate()
        chars = [:]
        link = .scanning
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let p = self.peripheral { self.connect(p) } else { self.startScan() }
            }
        }
    }
}

extension MugManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] {
                chars[c.uuid.uuidString.uppercased()] = c
                if c.uuid.uuidString.uppercased() == EmberUUID.pushEvents { p.setNotifyValue(true, for: c) }
            }
            for uuid in [EmberUUID.firmware, EmberUUID.ledColor, EmberUUID.battery, EmberUUID.liquidLevel] {
                if let c = chars[uuid] { p.readValue(for: c) }
            }
            link = .connected
            startPolling()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        let uuid = c.uuid.uuidString.uppercased()
        MainActor.assumeIsolated {
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
            case EmberUUID.ledColor: led = EmberCodec.decodeLED(data)
            case EmberUUID.pushEvents: poll()
            default: break
            }
        }
    }
}
