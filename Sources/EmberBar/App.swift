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
            MenuLabel(mug: mug)
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
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: mug.pulsing || mug.state == .heating ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill")
            if mug.link == .connected, mug.state.hasLiquid {
                Text(mug.unit.format(mug.temp))
            }
        }
    }
}

// MARK: - Shared pieces

extension MugManager {
    var statusLine: String {
        guard link == .connected else { return link.label }
        if !state.hasLiquid { return "Empty" }
        if pulsing { return "Warming gently" }
        if let g = goal, let t = temp, t > g + 0.5 { return "Cooling toward \(unit.format(g))" }
        if goal != nil { return "Holding" }
        return "Heater off, cooling naturally"
    }

    func modeDescription(_ mode: Mode) -> String {
        switch mode {
        case .off: return "Heater off"
        case .hold(let t): return "Hold \(unit.format(t))" + (t < MugLimits.floor ? " (pulsed)" : "")
        case .glide(let steps):
            return steps.map { unit.format($0.target) + ($0.minutes.map { " \(Int($0))m" } ?? "") }.joined(separator: " → ")
        }
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
                    if let g = mug.goal { Text("Goal \(mug.unit.format(g))").font(.caption).foregroundStyle(.secondary) }
                }
            }

            let recent = mug.history.filter { $0.time > Date().addingTimeInterval(-20 * 60) }
            if recent.count > 2 {
                Sparkline(samples: recent, unit: mug.unit).frame(height: 60)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(mug.presets) { p in
                    Button { mug.apply(p) } label: {
                        Text(p.name).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(mug.activePresetID == p.id && mug.mode == p.mode ? .orange : nil)
                    .help(mug.modeDescription(p.mode))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Hold at \(mug.unit.format(holdC))").font(.caption)
                TempSlider(celsius: _holdC.projectedValue) { mug.setHold(celsius: $0) }
            }

            HStack {
                Text("Now: \(mug.modeDescription(mug.mode))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                        if let t = mug.mugTarget {
                            Text("Mug's own target: \(t == 0 ? "off" : mug.unit.format(t))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
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
                            VStack { Text(p.name).bold(); Text(mug.modeDescription(p.mode)).font(.caption).lineLimit(2) }
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
                        VStack(alignment: .leading) {
                            Text(p.name).bold()
                            Text(mug.modeDescription(p.mode)).font(.caption).foregroundStyle(.secondary)
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
                Text("Below \(mug.unit.format(MugLimits.floor)) the mug won't hold a temperature by itself, so Ember Bar switches the heater on in short bursts while the Mac is near the mug. A glide steps the goal down over time, counted from when you pour.")
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
                Text("Hold at \(mug.unit.format(t))")
                TempSlider(celsius: binding)
            case .glide(let steps):
                Text("Steps, counted from when you pour").font(.headline)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    GlideStepRow(step: step, isLast: i == steps.count - 1) { new in
                        var s = steps; s[i] = new; preset.mode = .glide(s)
                    } remove: {
                        var s = steps; s.remove(at: i); preset.mode = .glide(s)
                    }
                }
                Button("Add step") {
                    var s = steps
                    if let last = s.indices.last, s[last].minutes == nil { s[last].minutes = 10 }
                    s.append(GlideStep(target: max(30, (s.last?.target ?? 45) - 3), minutes: nil))
                    preset.mode = .glide(s)
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
                Text(mug.unit.format(step.target)).frame(width: 44, alignment: .leading)
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
            Section("LED") {
                ColorPicker("Mug light", selection: Binding(
                    get: { mug.led.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) } ?? .white },
                    set: { c in
                        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
                        mug.setLED(.init(r: UInt8(ns.redComponent * 255), g: UInt8(ns.greenComponent * 255), b: UInt8(ns.blueComponent * 255)))
                    }), supportsOpacity: false)
            }
            Section("Gentle heating (below \(mug.unit.format(MugLimits.floor)))") {
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
