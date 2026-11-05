import AppKit
import Charts
import EmberCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var mug: MugManager?
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { mug?.prepareForQuit() }
    }
}

@main
struct EmberBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var mug = MugManager()

    var body: some Scene {
        MenuBarExtra {
            CompactView()
                .environmentObject(mug)
                .onAppear { delegate.mug = mug }
        } label: {
            MenuLabel(mug: mug, clock: mug.iconClock)
                .onAppear { delegate.mug = mug }
        }
        .menuBarExtraStyle(.window)

        Window("Ember Bar", id: "main") {
            MainWindow()
                .environmentObject(mug)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 860, height: 640)
    }
}

struct MenuLabel: View {
    @ObservedObject var mug: MugManager
    @ObservedObject var clock: IconClock
    var body: some View {
        let phase = mug.phase
        let showTemps = phase != .unavailable
        Image(nsImage: StatusIcon.image(phase: phase,
                                        temp: showTemps ? mug.unit.format(mug.temp) : nil,
                                        goal: showTemps ? mug.goal.map { "→" + mug.unit.format($0) } : nil,
                                        frame: clock.frame))
    }
}

/// The menu-bar icon: a cup tinted by what the heater is doing, the coffee's temperature and, under it in
/// smaller type, the goal. Drawn at display time so the text follows the menu bar's light or dark look.
enum StatusIcon {
    static func tint(_ phase: HeaterPhase) -> NSColor {
        switch phase {
        case .unavailable: .labelColor
        case .heating, .holding: .systemOrange
        case .coolingToGoal: .systemBlue
        case .resting: .systemPurple
        case .heaterOff: .systemTeal
        }
    }

    /// Breathing, in frames of 1/6 s: quicker while heating, slow while cooling down. Nil = steady.
    static func period(_ phase: HeaterPhase) -> Double? {
        switch phase {
        case .heating: 10
        case .coolingToGoal: 18
        default: nil
        }
    }

    static func image(phase: HeaterPhase, temp: String?, goal: String?, frame: Int) -> NSImage {
        let symbolName = phase == .heating ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [tint(phase)]))
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ember mug")?
            .withSymbolConfiguration(config) ?? NSImage()
        let alpha = period(phase).map { 0.55 + 0.45 * (0.5 + 0.5 * cos(2 * .pi * Double(frame) / $0)) } ?? 1

        let big = NSFont.monospacedDigitSystemFont(ofSize: goal == nil ? 13 : 10.5, weight: goal == nil ? .regular : .semibold)
        let small = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        let tempWidth = temp.map { ($0 as NSString).size(withAttributes: [.font: big]).width } ?? 0
        let goalWidth = goal.map { ($0 as NSString).size(withAttributes: [.font: small]).width } ?? 0
        let textWidth = ceil(max(tempWidth, goalWidth))
        let height: CGFloat = 22
        let size = NSSize(width: symbol.size.width + (textWidth > 0 ? 3 + textWidth : 0), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(at: NSPoint(x: 0, y: (height - symbol.size.height) / 2), from: .zero, operation: .sourceOver, fraction: alpha)
            let x = symbol.size.width + 3
            if let goal, let temp {
                (temp as NSString).draw(at: NSPoint(x: x, y: 9), withAttributes: [.font: big, .foregroundColor: NSColor.labelColor])
                (goal as NSString).draw(at: NSPoint(x: x, y: 0.5), withAttributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
            } else if let temp {
                (temp as NSString).draw(at: NSPoint(x: x, y: (height - big.boundingRectForFont.height) / 2 + 1),
                                        withAttributes: [.font: big, .foregroundColor: NSColor.labelColor])
            }
            return true
        }
        image.isTemplate = phase == .unavailable
        image.accessibilityDescription = ["Ember mug", temp, goal.map { "goal \($0.dropFirst())" }].compactMap { $0 }.joined(separator: ", ")
        return image
    }
}

// MARK: - Shared pieces

extension MugManager {
    var statusLine: String {
        guard link == .connected else { return link.label }
        if let paused = pausedText { return paused }
        switch phase {
        case .unavailable: return "Empty"
        case .heating: return pulsing ? "Warming gently" : "Heating"
        case .coolingToGoal: return "Cooling toward \(unit.format(goal))"
        case .resting: return "Heater resting between bursts"
        case .holding: return "Holding"
        case .heaterOff: return "Heater off, cooling naturally"
        }
    }

    func modeDescription(_ mode: Mode) -> String {
        switch mode {
        case .off: return "Heater off"
        case .hold(let t): return "Hold \(unit.dual(t))" + pulsedSuffix(mode)
        case .glide(let steps):
            return steps.map { unit.format($0.target) + ($0.minutes.map { " \(Int($0))m" } ?? "") }.joined(separator: " → ")
        }
    }

    func pulsedSuffix(_ mode: Mode) -> String { mode.isCycling ? ", pulsed" : "" }

    /// "≈ 112°F / 44°C avg" for modes Ember Bar cycles (the coffee swings, so the target alone misleads).
    func averageNote(_ mode: Mode) -> String? {
        guard mode.isCycling, let a = controller.approxAverage(mode) else { return nil }
        if case .glide = mode { return "≈ \(unit.dual(a)) avg over a 30-min cup" }
        return "≈ \(unit.dual(a)) avg"
    }

    /// Short lines for a preset button: the temperature it holds in both units, then its average when it cycles.
    func presetCaption(_ mode: Mode) -> [String] {
        let avg = mode.isCycling ? controller.approxAverage(mode).map { "≈ \(unit.format($0))\(unit.rawValue) avg" } : nil
        switch mode {
        case .off: return ["heater off"]
        case .hold(let t): return [unit.dual(t)] + [avg].compactMap { $0 }
        case .glide: return ["glide"] + [avg].compactMap { $0 }
        }
    }
}

extension EmberCodec.RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    init?(_ color: Color) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: UInt8((ns.redComponent * 255).rounded()), g: UInt8((ns.greenComponent * 255).rounded()),
                  b: UInt8((ns.blueComponent * 255).rounded()))
    }
}

struct TempSlider: View {
    @EnvironmentObject var mug: MugManager
    @Binding var celsius: Double
    var onCommit: (Double) -> Void = { _ in }

    var body: some View {
        let lo = mug.unit.display(30), hi = mug.unit.display(MugLimits.ceiling)
        Slider(value: Binding(get: { mug.unit.display(celsius) },
                              set: { celsius = mug.unit.toCelsius($0) }),
               in: lo...hi, step: mug.unit == .celsius ? 0.5 : 1) { editing in
            if !editing { onCommit(celsius) }
        }
    }
}

/// On / Off and Pause, in the popover and the window.
struct PowerRow: View {
    @EnvironmentObject var mug: MugManager

    var body: some View {
        HStack(spacing: 8) {
            if let paused = mug.pausedText {
                Button { mug.stayOff() } label: { Label("Stay off", systemImage: "power") }
                    .buttonStyle(.bordered)
                    .help("Paused. Click to end the pause and keep the heater off.")
                Button("Resume") { mug.turnOn() }.buttonStyle(.bordered).help(paused)
                if mug.link != .connected {  // otherwise the status line above already says until when
                    Text(paused).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button { mug.isOn ? mug.turnOff() : mug.turnOn() } label: {
                    Label(mug.isOn ? "Turn off" : "Turn on", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .tint(mug.isOn ? .orange : nil)
                .help(mug.isOn ? "Heater on. Click to turn it off." : "Heater off. Click to go back to your last program.")
                Menu {
                    Button("15 minutes") { mug.pause(minutes: 15) }
                    Button("30 minutes") { mug.pause(minutes: 30) }
                    Button("1 hour") { mug.pause(minutes: 60) }
                } label: { Label("Pause", systemImage: "pause.fill") }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(!mug.isOn)
                .help("Heater off for a while, then back to this program by itself.")
            }
            Spacer()
        }
    }
}

struct Sparkline: View {
    let samples: [Sample]
    let unit: TempUnit
    var body: some View {
        Chart {
            ForEach(samples) { s in
                LineMark(x: .value("Time", s.time), y: .value("Temp", unit.display(s.temp)))
                    .foregroundStyle(.orange)
                if let g = s.goal {
                    LineMark(x: .value("Time", s.time), y: .value("Goal", unit.display(g)), series: .value("s", "goal"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

// MARK: - Menu bar popover

struct CompactView: View {
    @EnvironmentObject var mug: MugManager
    @Environment(\.openWindow) private var openWindow
    private let _holdC = State<Double>(initialValue: 37.0)
    private var holdC: Double { get { _holdC.wrappedValue } nonmutating set { _holdC.wrappedValue = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mug.name).font(.headline)
                    Text(mug.link.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { mug.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reconnect")
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("Open Ember Bar")
            }

            HStack(alignment: .firstTextBaseline) {
                Text(mug.unit.format(mug.temp, decimals: 1)).font(.system(size: 40, weight: .semibold, design: .rounded))
                VStack(alignment: .leading) {
                    Text(mug.statusLine).font(.callout)
                    if let g = mug.goal { Text("Goal \(mug.unit.dual(g))").font(.caption).foregroundStyle(.secondary) }
                }
            }

            PowerRow()

            let recent = mug.history.filter { $0.time > Date().addingTimeInterval(-20 * 60) }
            if recent.count > 2 {
                Sparkline(samples: recent, unit: mug.unit).frame(height: 60)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(mug.presets) { p in
                    Button { mug.apply(p) } label: {
                        VStack(spacing: 1) {
                            Text(p.name)
                            ForEach(mug.presetCaption(p.mode), id: \.self) {
                                Text($0).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(mug.activePresetID == p.id && mug.mode == p.mode ? .orange : nil)
                    .help([mug.modeDescription(p.mode), mug.averageNote(p.mode)].compactMap { $0 }.joined(separator: "\n"))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Hold at \(mug.unit.dual(holdC))" + (mug.averageNote(.hold(holdC)).map { ", pulsed, \($0)" } ?? "")).font(.caption)
                TempSlider(celsius: _holdC.projectedValue) { mug.setHold(celsius: $0) }
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Now: \(mug.modeDescription(mug.mode))").lineLimit(1)
                    if let avg = mug.averageNote(mug.mode) { Text(avg).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let b = mug.battery {
                    Label("\(b.percent)%", systemImage: b.charging ? "battery.100.bolt" : "battery.75")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { if case .hold(let t) = mug.mode { holdC = t } }
    }
}

// MARK: - Main window

struct MainWindow: View {
    @EnvironmentObject var mug: MugManager
    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink(value: "now") { Label("Now", systemImage: "cup.and.saucer") }
                NavigationLink(value: "presets") { Label("Presets & cycles", systemImage: "list.bullet") }
                NavigationLink(value: "mug") { Label("Mug", systemImage: "gearshape") }
            }
            .navigationDestination(for: String.self) { page in
                switch page {
                case "presets": PresetsPage()
                case "mug": MugPage()
                default: NowPage()
                }
            }
        } detail: {
            NowPage()
        }
        .toolbar {
            Button { mug.reconnect() } label: { Image(systemName: "arrow.clockwise") }.help("Reconnect")
        }
    }
}

struct NowPage: View {
    @EnvironmentObject var mug: MugManager
    private let _window = State<Double>(initialValue: 60.0)
    private var window: Double { get { _window.wrappedValue } nonmutating set { _window.wrappedValue = newValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(mug.unit.format(mug.temp, decimals: 1)).font(.system(size: 56, weight: .semibold, design: .rounded))
                    VStack(alignment: .leading) {
                        Text(mug.statusLine).font(.title3)
                        Text("Mode: \(mug.modeDescription(mug.mode))").foregroundStyle(.secondary)
                        if let avg = mug.averageNote(mug.mode) { Text(avg).foregroundStyle(.secondary) }
                        if let t = mug.mugTarget {
                            Text("Mug's own target: \(t == 0 ? "off" : mug.unit.format(t))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                PowerRow()
                Picker("Show", selection: _window.projectedValue) {
                    Text("15 min").tag(15.0); Text("1 hour").tag(60.0); Text("4 hours").tag(240.0)
                }.pickerStyle(.segmented).frame(width: 280)
                let samples = mug.history.filter { $0.time > Date().addingTimeInterval(-window * 60) }
                if samples.count > 2 {
                    Chart {
                        ForEach(samples) { s in
                            if s.heating {
                                RectangleMark(x: .value("Time", s.time), width: .fixed(3))
                                    .foregroundStyle(.orange.opacity(0.12))
                            }
                            LineMark(x: .value("Time", s.time), y: .value("Coffee", mug.unit.display(s.temp)),
                                     series: .value("s", "Coffee"))
                                .foregroundStyle(.orange)
                            if let g = s.goal {
                                LineMark(x: .value("Time", s.time), y: .value("Goal", mug.unit.display(g)),
                                         series: .value("s", "Goal"))
                                    .foregroundStyle(.secondary)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 280)
                    Text("Orange line: coffee. Dashed: goal. Shaded: heater on.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The chart fills in while the mug is connected.").foregroundStyle(.secondary).frame(height: 120)
                }
                Text("Presets").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                    ForEach(mug.presets) { p in
                        Button { mug.apply(p) } label: {
                            VStack {
                                Text(p.name).bold()
                                Text(mug.presetCaption(p.mode).joined(separator: " · ")).font(.caption).lineLimit(2)
                            }
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(mug.activePresetID == p.id && mug.mode == p.mode ? .orange : nil)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Now")
    }
}

struct PresetsPage: View {
    @EnvironmentObject var mug: MugManager
    private let _editing = State<Preset?>(initialValue: nil)
    private var editing: Preset? { get { _editing.wrappedValue } nonmutating set { _editing.wrappedValue = newValue } }

    var body: some View {
        List {
            Section {
                ForEach(mug.presets) { p in
                    HStack {
                        if let light = p.light { Circle().fill(light.color).frame(width: 10, height: 10) }
                        VStack(alignment: .leading) {
                            Text(p.name).bold()
                            Text(mug.modeDescription(p.mode)).font(.caption).foregroundStyle(.secondary)
                            if let avg = mug.averageNote(p.mode) { Text(avg).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Use") { mug.apply(p) }
                        Button("Edit") { editing = p }
                        Button(role: .destructive) { mug.presets.removeAll { $0.id == p.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { mug.presets.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                HStack {
                    Text("Presets")
                    Spacer()
                    Button("New hold") { editing = Preset(name: "New hold", mode: .hold(40)) }
                    Button("New glide") {
                        editing = Preset(name: "New glide", mode: .glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 38, minutes: nil)]))
                    }
                    Button("Restore defaults") { mug.presets = Preset.defaults }
                }
            } footer: {
                Text("Below \(mug.unit.dual(MugLimits.lowestHeld)) the mug won't hold a temperature by itself, so Ember Bar switches the heater on in short bursts while the Mac is near the mug. The coffee swings a little around the goal, so those presets show an approximate average. A glide steps the goal down over time, counted from when you pour.")
            }
        }
        .sheet(item: _editing.projectedValue) { p in
            PresetEditor(preset: p) { saved in
                if let i = mug.presets.firstIndex(where: { $0.id == saved.id }) { mug.presets[i] = saved } else { mug.presets.append(saved) }
                if mug.activePresetID == saved.id { mug.mode = saved.mode }
                editing = nil
            } cancel: { editing = nil }
            .environmentObject(mug)
        }
        .navigationTitle("Presets & cycles")
    }
}

struct PresetEditor: View {
    @EnvironmentObject var mug: MugManager
    private let _preset: State<Preset>
    private var preset: Preset { get { _preset.wrappedValue } nonmutating set { _preset.wrappedValue = newValue } }
    let save: (Preset) -> Void
    let cancel: () -> Void

    init(preset: Preset, save: @escaping (Preset) -> Void, cancel: @escaping () -> Void) {
        _preset = State(initialValue: preset)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: _preset.projectedValue.name).textFieldStyle(.roundedBorder)
            switch preset.mode {
            case .off:
                Text("Heater stays off; the coffee cools on its own.")
            case .hold(let t):
                let binding = Binding(get: { t }, set: { preset.mode = .hold($0) })
                Text("Hold at \(mug.unit.dual(t))" + mug.pulsedSuffix(preset.mode))
                TempSlider(celsius: binding)
                if let avg = mug.averageNote(preset.mode) { Text(avg).font(.caption).foregroundStyle(.secondary) }
            case .glide(let steps):
                Text("Steps, counted from when you pour").font(.headline)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    GlideStepRow(step: step, isLast: i == steps.count - 1) { new in
                        var s = steps; s[i] = new; preset.mode = .glide(s)
                    } remove: {
                        var s = steps; s.remove(at: i); preset.mode = .glide(s)
                    }
                }
                if let avg = mug.averageNote(preset.mode) { Text(avg).font(.caption).foregroundStyle(.secondary) }
                Button("Add step") {
                    var s = steps
                    if let last = s.indices.last, s[last].minutes == nil { s[last].minutes = 10 }
                    s.append(GlideStep(target: max(30, (s.last?.target ?? 45) - 3), minutes: nil))
                    preset.mode = .glide(s)
                }
            }
            HStack {
                Toggle("Own mug light color", isOn: Binding(
                    get: { preset.light != nil },
                    set: { preset.light = $0 ? (mug.homeLight ?? .init(r: 255, g: 140, b: 0)) : nil }))
                if let light = preset.light {
                    ColorPicker("", selection: Binding(get: { light.color },
                                                       set: { if let c = EmberCodec.RGB($0) { preset.light = c } }),
                                supportsOpacity: false).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") { save(preset) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct GlideStepRow: View {
    @EnvironmentObject var mug: MugManager
    let step: GlideStep
    let isLast: Bool
    let change: (GlideStep) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(mug.unit.dual(step.target)).frame(width: 92, alignment: .leading)
                TempSlider(celsius: Binding(get: { step.target }, set: { var s = step; s.target = $0; change(s) }))
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            HStack {
                if let m = step.minutes {
                    Stepper("for \(Int(m)) min", value: Binding(get: { m }, set: { var s = step; s.minutes = max(1, $0); change(s) }), in: 1...120)
                } else {
                    Text("until the mug is empty").foregroundStyle(.secondary)
                }
                if isLast {
                    Toggle("Until empty", isOn: Binding(get: { step.minutes == nil },
                                                        set: { var s = step; s.minutes = $0 ? nil : 10; change(s) }))
                }
            }.font(.caption)
        }
    }
}

struct MugPage: View {
    @EnvironmentObject var mug: MugManager

    var body: some View {
        Form {
            Section("Display") {
                Picker("Units", selection: $mug.unit) {
                    Text("°F").tag(TempUnit.fahrenheit); Text("°C").tag(TempUnit.celsius)
                }.pickerStyle(.segmented)
            }
            Section("Light") {
                ColorPicker("Everyday mug light", selection: Binding(
                    get: { (mug.homeLight ?? mug.led)?.color ?? .white },
                    set: { if let c = EmberCodec.RGB($0) { mug.setHomeLight(c) } }), supportsOpacity: false)
                Toggle("Slow blink while Ember Bar cycles the heater", isOn: $mug.blinkWhileCycling)
                Text("A preset can have its own light color: Presets & cycles, Edit. It blinks, 6 seconds bright and 6 dim, whenever Ember Bar is pulsing the heater toward the goal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Gentle heating (below \(mug.unit.dual(MugLimits.lowestHeld)))") {
                LabeledContent("Heater comes on") {
                    Stepper(String(format: "%.1f° below goal", mug.controller.band * (mug.unit == .celsius ? 1 : 1.8)),
                            value: $mug.controller.band, in: 0.3...3, step: 0.1)
                }
                LabeledContent("Learned overshoot") {
                    HStack {
                        Text(String(format: "%.1f°", mug.controller.overshoot * (mug.unit == .celsius ? 1 : 1.8)))
                        Button("Reset") { mug.resetLearning() }
                    }
                }
                Text("After each burst the coffee keeps warming a little. Ember Bar measures how much and cuts the heater that much earlier next time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mug") {
                LabeledContent("Name", value: mug.name)
                LabeledContent("Connection", value: mug.link.label)
                LabeledContent("Battery", value: mug.battery.map { "\($0.percent)%\($0.charging ? ", charging" : "")" } ?? "–")
                LabeledContent("Liquid level", value: mug.level.map { "\($0) of 30" } ?? "–")
                LabeledContent("Version", value: mug.firmware ?? "–")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mug")
    }
}
