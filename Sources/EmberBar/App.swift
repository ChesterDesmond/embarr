import AppKit
import Charts
import EmberCore
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var mug: MugManager?
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { mug?.prepareForQuit() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dir = ProcessInfo.processInfo.environment["EMBERBAR_SNAPSHOT"] else { return }
        MainActor.assumeIsolated { Snapshot.run(into: URL(fileURLWithPath: dir)) }
    }
}

/// Development aid: `EMBERBAR_SNAPSHOT=<folder> "/Applications/Embarr.app/Contents/MacOS/EmberBar"` draws the
/// popover, the window's pages and a highlighted button (highlight.png) to PNGs and exits, so the layout can be
/// checked without clicking the menu bar.
/// Nothing in a snapshot run touches Bluetooth: every MugManager in it is made with `live: false`, so it shows the
/// saved programs and settings with no readings.
@MainActor
enum Snapshot {
    nonisolated static var requested: Bool { ProcessInfo.processInfo.environment["EMBERBAR_SNAPSHOT"] != nil }

    static func run(into dir: URL) {
        let mug = MugManager(live: false)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            write(CompactView().environmentObject(mug), size: NSSize(width: 320, height: 640), to: dir.appendingPathComponent("popover.png"))
            for (page, file) in [(WindowPage.programs, "programs.png"), (.mug, "mug.png")] {
                mug.windowPage = page
                write(MainWindow().environmentObject(mug), size: NSSize(width: 860, height: 640), to: dir.appendingPathComponent(file))
            }
            // A highlighted and a plain button side by side, since the saved settings may have nothing running.
            let pair = HStack {
                ForEach([true, false], id: \.self) { on in
                    Button {} label: { Text(on ? "Running" : "Not running").frame(maxWidth: .infinity) }.highlighted(on)
                }
            }
            write(pair.padding().frame(width: 300), size: NSSize(width: 300, height: 60), to: dir.appendingPathComponent("highlight.png"))
            let batteries = HStack(spacing: 14) {
                ForEach([(100, false), (70, false), (40, false), (12, false), (30, true)], id: \.0) {
                    BatteryBadge(battery: .init(percent: $0.0, charging: $0.1))
                }
            }
            write(VStack(alignment: .leading, spacing: 10) { Wordmark(size: 20); batteries }.padding().frame(width: 320, alignment: .leading),
                  size: NSSize(width: 320, height: 110), to: dir.appendingPathComponent("header-battery.png"))
            write(PresetEditor(preset: Preset(name: "New program", mode: .hold(40)), save: { _ in }, cancel: {}).environmentObject(mug),
                  size: NSSize(width: 440, height: 360), to: dir.appendingPathComponent("editor.png"))
            exit(0)
        }
    }

    private static func write<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))  // drawn for real, but off every screen
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// A bordered button that shows it is the current choice (the running program): an orange outline and wash, drawn
/// by hand over the bezel. macOS draws a `.bordered` button the same whatever its tint, and grays a
/// `.borderedProminent` one whenever its window isn't frontmost, so neither showed it.
struct Highlighted: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .buttonStyle(.bordered)
            .overlay {
                shape.fill(Color.orange.opacity(on ? 0.25 : 0))
                    .overlay(shape.strokeBorder(Color.orange, lineWidth: on ? 2 : 0))
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension View {
    func highlighted(_ on: Bool) -> some View { modifier(Highlighted(on: on)) }
}

@main
struct EmberBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var mug = MugManager(live: !Snapshot.requested)

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

        Window("Embarr", id: "main") {
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
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let phase = mug.phase
        let showTemps = phase != .unavailable
        Image(nsImage: StatusIcon.image(phase: phase,
                                        temp: showTemps ? mug.unit.format(mug.temp) : nil,
                                        goal: showTemps ? mug.goal.map { "→" + mug.unit.format($0) } : nil,
                                        frame: clock.frame))
            .onAppear {
                AppActions.openWindow = openWindow
                if !Snapshot.requested { StatusMenu.shared.install(mug: mug) }
            }
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
        if link == .scanning && !hasPairedMug { return "Choose your mug" }
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

    /// "≈ 112°F / 44°C avg" for modes Embarr cycles (the drink swings, so the target alone misleads).
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

extension TempColor {
    static func color(_ celsius: Double) -> Color { rgb(celsius).color }
}

/// The temperature slider, color-coded: its track runs blue (cool) through amber at 120 F (where the mug holds by
/// itself; below it Embarr pulses the heater) to red, and the thumb takes the color of the value. Drawn by hand
/// because macOS sliders ignore tint. Drag or click anywhere on it; arrow keys and VoiceOver step it.
struct TempSlider: View {
    @EnvironmentObject var mug: MugManager
    @Binding var celsius: Double
    var onCommit: (Double) -> Void = { _ in }

    static let range = MugLimits.sliderFloor...MugLimits.ceiling
    private static let thumb: CGFloat = 16
    /// A key-held change waits here and is sent shortly after the last step, in case the key-up never arrives
    /// (focus moved, popover closed). Spelled out as `State(initialValue:)` like the rest of this file: the @State macro
    /// isn't available with Command Line Tools only.
    private let _pending = State(initialValue: PendingCommit())

    /// One step in the shown unit: half a degree C, or a whole degree F.
    private var step: Double { mug.unit == .celsius ? 0.5 : 1 }

    private func snapped(_ c: Double) -> Double {
        let d = (mug.unit.display(c) / step).rounded() * step
        return min(max(mug.unit.toCelsius(d), Self.range.lowerBound), Self.range.upperBound)
    }

    private func nudge(_ steps: Double, commit: Bool = true) {
        celsius = snapped(mug.unit.toCelsius(mug.unit.display(celsius) + steps * step))
        if commit { onCommit(celsius) }
    }

    var body: some View {
        let span = Self.range.upperBound - Self.range.lowerBound
        let stops = TempColor.stops.map { Gradient.Stop(color: $0.rgb.color, location: ($0.celsius - Self.range.lowerBound) / span) }
        let heldAt = (MugLimits.lowestHeld - Self.range.lowerBound) / span
        GeometryReader { geo in
            let usable = max(1, geo.size.width - Self.thumb)
            let position = (min(max(celsius, Self.range.lowerBound), Self.range.upperBound) - Self.range.lowerBound) / span
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                    .frame(width: usable, height: 6)
                    .offset(x: Self.thumb / 2)
                Rectangle().fill(.primary.opacity(0.55)).frame(width: 1.5, height: 12)
                    .offset(x: Self.thumb / 2 + usable * heldAt)
                Circle()
                    .fill(TempColor.color(celsius))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: usable * position)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    celsius = snapped(Self.range.lowerBound + Double((v.location.x - Self.thumb / 2) / usable) * span)
                }
                .onEnded { _ in onCommit(celsius) })
        }
        .frame(height: 20)
        .focusable()
        // Holding an arrow moves the thumb; the mug gets the value once, on release.
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat, .up]) { press in
            if press.phase == .up {
                _pending.wrappedValue.cancel()
                onCommit(celsius)
            } else {
                nudge(press.key == .leftArrow ? -1 : 1, commit: false)
                let commit = onCommit, binding = $celsius
                _pending.wrappedValue.schedule(after: 0.8) { commit(binding.wrappedValue) }
            }
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Temperature")
        .accessibilityValue(mug.unit.dual(celsius))
        .accessibilityAdjustableAction { nudge($0 == .increment ? 1 : -1) }
        .help("Blue is cool, red is hot. The mark is \(mug.unit.dual(MugLimits.lowestHeld)): the mug holds that and above by itself; below it Embarr pulses the heater.")
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
                    Label { Text(mug.isOn ? "Turn off" : "Turn on") } icon: {
                        Image(systemName: "power").foregroundStyle(mug.isOn ? Color.orange : Color.primary)
                    }
                }
                .buttonStyle(.bordered)
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
    /// What the inline name box is naming, if it's open. (Inline, not an alert: an alert over a menu-bar panel can
    /// close along with the panel.)
    private let _naming = State<Naming?>(initialValue: nil)
    private var naming: Naming? { get { _naming.wrappedValue } nonmutating set { _naming.wrappedValue = newValue } }
    private let _nameProblem = State<String?>(initialValue: nil)
    private var nameProblem: String? { get { _nameProblem.wrappedValue } nonmutating set { _nameProblem.wrappedValue = newValue } }

    enum Naming: Equatable {
        case program(UUID), mug, newHold(Double)
        var title: String {
            switch self {
            case .program: "Rename program"
            case .mug: "Rename mug"
            case .newHold: "Save as program"
            }
        }
    }

    private func startNaming(_ what: Naming, _ current: String) {
        draftName = current
        nameProblem = nil
        naming = what
    }

    private func finishNaming() {
        switch naming {
        case .program(let id)?: mug.renameProgram(id, to: draftName)
        case .newHold(let c)?: mug.addProgram(name: draftName, mode: .hold(c))
        case .mug?:
            if let problem = mug.renameMug(draftName) { nameProblem = problem; return }
        case nil: break
        }
        naming = nil
    }

    @ViewBuilder private var nameBox: some View {
        if let what = naming {
            VStack(alignment: .leading, spacing: 4) {
                Text(what.title).font(.caption).bold()
                HStack {
                    TextField("Name", text: _draftName.projectedValue).textFieldStyle(.roundedBorder).onSubmit(finishNaming)
                    Button("Save", action: finishNaming).keyboardShortcut(.defaultAction)
                    Button("Cancel") { naming = nil }
                }
                if let problem = nameProblem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        }
    }
    private let _draftName = State<String>(initialValue: "")
    private var draftName: String { get { _draftName.wrappedValue } nonmutating set { _draftName.wrappedValue = newValue } }

    private func openEditor(_ preset: Preset) {
        mug.openInWindow(page: .programs, editing: preset)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Wordmark()
                    Spacer()
                    Button { AppActions.open(mug: mug) } label: { Image(systemName: "macwindow") }
                        .buttonStyle(.borderless).help("Open Embarr")
                    AppMenuButton()
                }
                EmberRule()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(mug.name).font(.headline)
                        if mug.link == .connected {
                            Button { startNaming(.mug, mug.name) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Rename the mug")
                        }
                    }
                    Text(mug.link.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let b = mug.battery { BatteryBadge(battery: b).font(.caption) }
                Button { mug.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reconnect")
            }

            HStack(alignment: .firstTextBaseline) {
                Text(mug.unit.format(mug.temp, decimals: 1)).font(.system(size: 40, weight: .semibold, design: .rounded))
                VStack(alignment: .leading) {
                    Text(mug.statusLine).font(.callout)
                    if let g = mug.goal { Text("Goal \(mug.unit.dual(g))").font(.caption).foregroundStyle(.secondary) }
                }
            }

            nameBox
            if let err = mug.mugProblem { Text(err).font(.caption).foregroundStyle(.red) }
            if mug.link.bluetoothUnavailable { BluetoothHint() }
            else if !mug.hasPairedMug { NearbyMugsList() }
            else if mug.mugMissing {
                Text("Not finding your mug? Wake it, and quit Ember's app on your phone. Still nothing: open Settings, Forget this mug, and connect it again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            PowerRow()

            let recent = mug.history.filter { $0.time > Date().addingTimeInterval(-20 * 60) }
            if recent.count > 2 {
                Sparkline(samples: recent, unit: mug.unit).frame(height: 60)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(mug.presets) { p in
                    Button { mug.tap(p) } label: {
                        VStack(spacing: 1) {
                            Text(p.name)
                            ForEach(mug.presetCaption(p.mode), id: \.self) {
                                Text($0).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .highlighted(mug.isRunning(p))
                    .help([mug.modeDescription(p.mode), mug.averageNote(p.mode),
                           mug.isRunning(p) ? mug.runningTileClick : nil]
                        .compactMap { $0 }.joined(separator: "\n"))
                    .contextMenu {
                        Button("Rename…") { startNaming(.program(p.id), p.name) }
                        Button("Edit…") { openEditor(p) }
                        Divider()
                        Button("Delete", role: .destructive) { mug.deleteProgram(p.id) }
                    }
                }
                Button { openEditor(Preset(name: "New program", mode: .hold(holdC))) } label: {
                    Label("New program", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Add a program: a hold or a glide. Right-click a program to rename, edit or delete it.")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle().fill(TempColor.color(holdC)).frame(width: 8, height: 8)
                    Text("Hold at \(mug.unit.dual(holdC))" + (mug.averageNote(.hold(holdC)).map { ", pulsed, \($0)" } ?? "")).font(.caption)
                    Spacer()
                    Button("Save as program") {
                        startNaming(.newHold((holdC * 10).rounded() / 10), "Hold \(mug.unit.format(holdC))\(mug.unit.rawValue)")
                    }
                        .buttonStyle(.borderless).font(.caption)
                }
                TempSlider(celsius: _holdC.projectedValue) { mug.setHold(celsius: $0) }
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Now: \(mug.modeDescription(mug.mode))").lineLimit(1)
                    if let avg = mug.averageNote(mug.mode) { Text(avg).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
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
            List(selection: Binding<WindowPage?>(get: { mug.windowPage }, set: { if let p = $0 { mug.windowPage = p } })) {
                Label("Now", systemImage: "cup.and.saucer").tag(WindowPage.now)
                Label("Programs", systemImage: "list.bullet").tag(WindowPage.programs)
                Label("Settings", systemImage: "gearshape").tag(WindowPage.mug)
            }
        } detail: {
            switch mug.windowPage {
            case .now: NowPage()
            case .programs: PresetsPage()
            case .mug: MugPage()
            }
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
                            Text("Mug's heater setting right now: \(t == 0 ? "off" : mug.unit.format(t))")
                                .font(.caption).foregroundStyle(.secondary)
                                .help("What the mug itself is set to, read from it every few seconds. Embarr normally sets it, so it matches your goal from \(mug.unit.dual(MugLimits.lowestHeld)) up. Below that, Embarr switches the heater on and off in short bursts, so this flips between \(mug.unit.format(MugLimits.pulseOn)) and off.")
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
                            LineMark(x: .value("Time", s.time), y: .value("Drink", mug.unit.display(s.temp)),
                                     series: .value("s", "Drink"))
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
                    Text("Orange line: drink. Dashed: goal. Shaded: heater on.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The chart fills in while the mug is connected.").foregroundStyle(.secondary).frame(height: 120)
                }
                Text("Programs").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                    ForEach(mug.presets) { p in
                        Button { mug.tap(p) } label: {
                            VStack {
                                Text(p.name).bold()
                                Text(mug.presetCaption(p.mode).joined(separator: " · ")).font(.caption).lineLimit(2)
                            }
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .highlighted(mug.isRunning(p))
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
                        if mug.isRunning(p) {
                            Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.orange).font(.caption)
                        }
                        Button("Use") { mug.apply(p) }
                        Button("Edit") { editing = p }
                        Button(role: .destructive) { mug.deleteProgram(p.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { mug.presets.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                HStack {
                    Text("Programs")
                    Spacer()
                    Button("New program") { editing = Preset(name: "New program", mode: .hold(40)) }
                    Menu("Share") {
                        Button("Export programs…", action: exportPrograms)
                        Button("Import programs…", action: importPrograms)
                    }
                    .fixedSize()
                    Button("Restore defaults") { mug.presets = Preset.defaults }
                }
            } footer: {
                if let note = shareNote { Text(note) }
            }
            Section("How programs heat") { ModeGuide() }
        }
        .sheet(item: _editing.projectedValue) { p in
            PresetEditor(preset: p) { saved in
                if let i = mug.presets.firstIndex(where: { $0.id == saved.id }) { mug.presets[i] = saved } else { mug.presets.append(saved) }
                if mug.activePresetID == saved.id { mug.mode = saved.mode }
                editing = nil
            } cancel: { editing = nil }
            .environmentObject(mug)
        }
        .navigationTitle("Programs")
        .onAppear(perform: takeEditRequest)
        .onChange(of: mug.editRequest) { takeEditRequest() }
    }

    private let _shareNote = State<String?>(initialValue: nil)
    private var shareNote: String? { get { _shareNote.wrappedValue } nonmutating set { _shareNote.wrappedValue = newValue } }

    /// Saves every program to a file another Embarr user can import. Only the programs: not the paired mug.
    private func exportPrograms() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Embarr programs.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try mug.exportPrograms(to: url)
            let n = mug.presets.count == 1 ? "1 program" : "\(mug.presets.count) programs"
            shareNote = "Saved \(n) to \(url.lastPathComponent). Send that file to someone with Embarr; they use Share, Import programs."
        } catch {
            shareNote = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func importPrograms() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        shareNote = mug.importPrograms(from: url)
    }

    private func takeEditRequest() {
        guard let p = mug.editRequest else { return }
        mug.editRequest = nil
        editing = p
    }
}

/// The Programs page's guide to the four ways a program can heat, each with a sketch of the coffee's temperature
/// over time.
struct ModeGuide: View {
    @EnvironmentObject var mug: MugManager

    private struct Entry: Identifiable {
        let title: String, text: String, sketch: [CGPoint], tint: Color
        var id: String { title }
    }

    private var entries: [Entry] {
        let floor = mug.unit.dual(MugLimits.lowestHeld)
        let off = stride(from: 0.0, through: 1.0, by: 0.05).map { CGPoint(x: $0, y: 0.08 + 0.84 * (1 - exp(-2.5 * $0))) }
        return [
            Entry(title: "Hold, \(floor) and up",
                  text: "The mug keeps your drink at that temperature by itself, even when the Mac is asleep or away.",
                  sketch: [.init(x: 0, y: 0.08), .init(x: 0.25, y: 0.45), .init(x: 0.35, y: 0.5), .init(x: 1, y: 0.5)],
                  tint: TempColor.color(55)),
            Entry(title: "Hold, below \(floor)",
                  text: "The mug won't hold this low, so Embarr switches the heater on in short bursts. The Mac has to be on and near the mug. The drink swings a little around the goal, so these programs show an average.",
                  sketch: [.init(x: 0, y: 0.08), .init(x: 0.3, y: 0.62), .init(x: 0.4, y: 0.72), .init(x: 0.47, y: 0.62),
                           .init(x: 0.6, y: 0.72), .init(x: 0.67, y: 0.62), .init(x: 0.8, y: 0.72), .init(x: 0.87, y: 0.62),
                           .init(x: 1, y: 0.72)],
                  tint: TempColor.color(42)),
            Entry(title: "Glide",
                  text: "Steps the goal down over time, counted from when you pour, for a drink that tastes different as it cools. Embarr changes each step, so keep the Mac near the mug.",
                  sketch: [.init(x: 0, y: 0.08), .init(x: 0.15, y: 0.3), .init(x: 0.4, y: 0.3), .init(x: 0.48, y: 0.5),
                           .init(x: 0.7, y: 0.5), .init(x: 0.78, y: 0.7), .init(x: 1, y: 0.7)],
                  tint: TempColor.color(48)),
            Entry(title: "Heater off",
                  text: "Nothing heats. The drink cools on its own, the way \"Just let it cool\" works.",
                  sketch: off, tint: .secondary),
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Sketch(points: e.sketch)
                            .stroke(e.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 56, height: 28)
                        Text(e.title).bold()
                    }
                    Text(e.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
            }
        }
        .padding(.vertical, 4)
    }

    /// A line through `points`, each 0...1 across and down the frame (temperature falls downward).
    private struct Sketch: Shape {
        let points: [CGPoint]
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.addLines(points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) })
            return p
        }
    }
}

/// The app's version, copyright and license, at the bottom of the Mug page.
struct AboutSection: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        Section("About Embarr") {
            LabeledContent("Version", value: version)
            Text("© 2026 ChesterDesmond. Free to use, change and share under the MIT License. "
                 + "Not made by or affiliated with Ember Technologies, Inc. Ember is their trademark.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
            Picker("Type", selection: Binding(get: { ProgramKind(preset.mode) }, set: { preset.mode = $0.convert(preset.mode) })) {
                ForEach(ProgramKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            switch preset.mode {
            case .off:
                Text("Heater stays off; the drink cools on its own.")
            case .hold(let t):
                let binding = Binding(get: { t }, set: { preset.mode = .hold($0) })
                HStack {
                    Circle().fill(TempColor.color(t)).frame(width: 8, height: 8)
                    Text("Hold at \(mug.unit.dual(t))" + mug.pulsedSuffix(preset.mode))
                }
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
                Toggle("Custom light color", isOn: Binding(
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
    private let _loginOn = State<Bool>(initialValue: false)
    private var loginOn: Bool { get { _loginOn.wrappedValue } nonmutating set { _loginOn.wrappedValue = newValue } }
    private let _draftName = State<String>(initialValue: "")
    private var draftName: String { get { _draftName.wrappedValue } nonmutating set { _draftName.wrappedValue = newValue } }
    private let _nameProblem = State<String?>(initialValue: nil)
    private var nameProblem: String? { get { _nameProblem.wrappedValue } nonmutating set { _nameProblem.wrappedValue = newValue } }

    var body: some View {
        Form {
            Section("General") {
                Picker("Units", selection: $mug.unit) {
                    Text("°F").tag(TempUnit.fahrenheit); Text("°C").tag(TempUnit.celsius)
                }.pickerStyle(.segmented)
                Toggle("Open at Login", isOn: Binding(get: { loginOn }, set: {
                    nameProblem = LoginItem.set($0)
                    loginOn = LoginItem.isOn
                }))
                .onAppear { loginOn = LoginItem.isOn; mug.refreshNotificationPermission() }
                Toggle("Ask about the heater when the mug is off the charger", isOn: $mug.askOffCharger)
                if !mug.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                        }
                    } label: {
                        Label("Notifications are off for Embarr, so you won't see these questions or the ready alerts.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Text("After a minute off the charger, a notification asks whether to turn the heater on (or keep it on). Set Embarr's notifications to Alerts in System Settings to keep it on screen until you answer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Light") {
                ColorPicker("Everyday mug light", selection: Binding(
                    get: { (mug.homeLight ?? mug.led)?.color ?? .white },
                    set: { if let c = EmberCodec.RGB($0) { mug.setHomeLight(c) } }), supportsOpacity: false)
                Toggle("Slow blink while Embarr cycles the heater", isOn: $mug.blinkWhileCycling)
                Text("A program can have a custom light color: Programs, Edit. It blinks, 6 seconds bright and 6 dim, whenever Embarr is pulsing the heater toward the goal.")
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
                Text("After each burst the drink keeps warming a little. Embarr measures how much and cuts the heater that much earlier next time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mug") {
                LabeledContent("Name") {
                    HStack {
                        TextField("Name", text: _draftName.projectedValue).labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                            .onAppear { draftName = mug.name }
                            .onChange(of: mug.name) { old, new in if draftName == old { draftName = new } }
                        Button("Rename") { nameProblem = mug.renameMug(draftName) }
                            .disabled(draftName == mug.name || mug.link != .connected)
                    }
                }
                if let problem = nameProblem ?? mug.mugProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                if mug.hasPairedMug {
                    LabeledContent("Paired mug") {
                        HStack {
                            Text(mug.name)
                            Button("Forget this mug") { mug.forgetMug() }
                        }
                    }
                    Text("The mug this Mac connects to, whether or not it's awake right now. Forget it to connect a different Ember. The heater is switched off first if Embarr was pulsing it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    NearbyMugsList()
                }
                LabeledContent("Connection", value: mug.link.label)
                LabeledContent("Battery") {
                    if let b = mug.battery {
                        HStack(spacing: 4) { BatteryBadge(battery: b); if b.charging { Text("charging") } }
                    } else { Text("–") }
                }
                LabeledContent("Liquid level", value: mug.level.map { "\($0) of 30" } ?? "–")
                LabeledContent("Mug firmware", value: mug.firmware ?? "–")
            }
            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}


/// "Mugs nearby": shown until this Mac has a mug of its own, with Connect for each Ember in range.
struct NearbyMugsList: View {
    @EnvironmentObject var mug: MugManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mugs nearby").font(.caption).bold()
            if mug.nearby.isEmpty {
                Text("Looking… Wake your mug (pick it up or set it on its coaster). Still nothing? Hold the button on the bottom until the light flashes blue, and quit Ember's app on your phone. The mug needs to have been set up in Ember's app once (after any reset).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(mug.nearby) { m in
                HStack {
                    Image(systemName: "cup.and.saucer.fill").foregroundStyle(.orange)
                    Text(m.name)
                    Spacer()
                    Button("Connect") { mug.pair(m.id) }
                }
            }
        }
    }
}

/// One delayed action that a newer one replaces (the slider's key-hold commit).
@MainActor
final class PendingCommit {
    private var item: DispatchWorkItem?
    func schedule(after seconds: Double, _ action: @escaping () -> Void) {
        item?.cancel()
        let next = DispatchWorkItem(block: action)
        item = next
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: next)
    }
    func cancel() { item?.cancel(); item = nil }
}

/// What to do when Bluetooth can't be used: turn it on, or allow Embarr in System Settings.
struct BluetoothHint: View {
    @EnvironmentObject var mug: MugManager

    var body: some View {
        if mug.link == .bluetoothDenied {
            VStack(alignment: .leading, spacing: 4) {
                Text("Embarr needs Bluetooth to reach the mug. Turn it on for Embarr in System Settings > Privacy & Security > Bluetooth.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Bluetooth settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else {
            Text("Turn Bluetooth on (Control Center, at the top right of the screen).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
