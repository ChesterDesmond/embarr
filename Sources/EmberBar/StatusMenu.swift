import AppKit
import EmberCore
import ServiceManagement
import SwiftUI

// MARK: - Wordmark

/// "Embarr" in an ember gradient: a serif italic with a small flame, over a tracked tagline. Heads the popover and
/// the right-click menu.
struct Wordmark: View {
    var size: CGFloat = 22
    var tagline = true

    static let ember = LinearGradient(
        colors: [Color(red: 1.0, green: 0.78, blue: 0.32), Color(red: 0.98, green: 0.5, blue: 0.12),
                 Color(red: 0.8, green: 0.18, blue: 0.12)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(Self.ember)
                    .baselineOffset(size * 0.04)
                Text("Embarr")
                    .font(.system(size: size, weight: .bold, design: .serif))
                    .italic()
                    .kerning(0.4)
                    .foregroundStyle(Self.ember)
            }
            if tagline {
                Text("FOR EMBER MUGS")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .kerning(size * 0.12)
                    .foregroundStyle(.secondary)
                    .padding(.leading, size * 0.68)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Embarr")
    }
}

/// A hairline in the same gradient, fading out at the right, under the popover's header.
struct EmberRule: View {
    var body: some View {
        Wordmark.ember
            .frame(height: 1)
            .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - Battery

extension BatteryTier {
    var color: Color {
        switch self {
        case .good: .green
        case .fair: .yellow
        case .low: .red
        }
    }
    var nsColor: NSColor {
        switch self {
        case .good: .systemGreen
        case .fair: .systemYellow
        case .low: .systemRed
        }
    }
}

extension EmberCodec.Battery {
    var label: String { "\(percent)%" + (charging ? ", charging" : "") }
}

/// The battery icon, colored by charge (green, yellow, red; green while charging), with the percentage.
struct BatteryBadge: View {
    let battery: EmberCodec.Battery
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: battery.symbolName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(battery.tier.color, Color.secondary)
            Text("\(battery.percent)%").monospacedDigit().lineLimit(1).fixedSize()
        }
        .help("Mug battery \(battery.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mug battery \(battery.label)")
    }
}

// MARK: - Open at Login

/// Embarr as a login item, through macOS's own list (System Settings > General > Login Items).
@MainActor
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Switches it, and returns why it couldn't, or nil. If macOS wants the user to approve it, opens Login Items.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return nil }
            return "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        if on && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return nil
    }
}

// MARK: - App actions shared by the popover's "…" menu and the right-click menu

@MainActor
enum AppActions {
    /// Set by the menu-bar label once it appears, since only a SwiftUI view can open a SwiftUI window.
    static var openWindow: OpenWindowAction?

    static func open(_ page: WindowPage? = nil, mug: MugManager) {
        if let page { mug.openInWindow(page: page) }
        openWindow?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    static func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

/// The popover's "…" menu: the app-level things that used to be one small Quit link.
struct AppMenuButton: View {
    @EnvironmentObject var mug: MugManager

    var body: some View {
        Menu {
            Button("Open Embarr") { AppActions.open(mug: mug) }
            Button("Settings…") { AppActions.open(.mug, mug: mug) }
            Divider()
            Toggle("Open at Login", isOn: Binding(get: { LoginItem.isOn }, set: { mug.mugProblem = LoginItem.set($0) }))
            Button("About Embarr") { AppActions.about() }
            UpdateMenuButton()
            Divider()
            Button("Quit Embarr") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings, Open at Login, Quit. Right-click the menu-bar icon for more.")
    }
}

// MARK: - Right-click menu on the menu-bar icon

/// SwiftUI's MenuBarExtra has no right-click, so a local event monitor catches a right-click (or Control-click) on
/// the status item's own window and shows this menu there instead of the popover.
@MainActor
final class StatusMenu: NSObject {
    static let shared = StatusMenu()
    weak var mug: MugManager?
    private var monitor: Any?

    func install(mug: MugManager) {
        self.mug = mug
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let wantsMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard wantsMenu, let window = event.window, NSStringFromClass(type(of: window)).contains("StatusBarWindow"),
                  let view = window.contentView else { return event }
            let target = view  // local monitors run on the main thread
            MainActor.assumeIsolated { StatusMenu.shared.show(under: target) }
            return nil
        }
    }

    private func show(under view: NSView) {
        guard let menu = makeMenu() else { return }
        let y = view.isFlipped ? view.bounds.maxY + 5 : view.bounds.minY - 5
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }

    private func item(_ title: String, key: String = "", _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.run), keyEquivalent: key)
        let target = ClosureTarget(action)
        item.target = target
        item.representedObject = target  // NSMenuItem holds its target weakly; this keeps it alive
        return item
    }

    private func symbol(_ name: String, _ color: NSColor? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let color else { return image }
        return image?.withSymbolConfiguration(.init(paletteColors: [color, .secondaryLabelColor]))
    }

    func makeMenu() -> NSMenu? {
        guard let mug else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem()
        let host = NSHostingView(rootView: Wordmark(size: 20).padding(.horizontal, 14).padding(.vertical, 6))
        host.frame.size = host.fittingSize
        header.view = host
        menu.addItem(header)

        let status = NSMenuItem(title: "\(mug.name): \(mug.statusLine)", action: nil, keyEquivalent: "")
        // Left enabled (with no action) so the icon keeps its color; a disabled item draws it gray.
        status.image = symbol("cup.and.saucer.fill", StatusIcon.tint(mug.phase))
        menu.addItem(status)
        if let b = mug.battery {
            let battery = NSMenuItem(title: "Battery \(b.label)", action: nil, keyEquivalent: "")
            battery.image = symbol(b.symbolName, b.tier.nsColor)
            menu.addItem(battery)
        }
        menu.addItem(.separator())

        let open = item("Open Embarr", key: "o") { AppActions.open(mug: mug) }
        open.image = symbol("macwindow")
        menu.addItem(open)
        let settings = item("Settings…", key: ",") { AppActions.open(.mug, mug: mug) }
        settings.image = symbol("gearshape")
        menu.addItem(settings)
        menu.addItem(.separator())

        if mug.pausedText != nil {
            menu.addItem(item("Resume Now") { mug.turnOn() })
            menu.addItem(item("Stay Off") { mug.stayOff() })
        } else {
            let power = item(mug.isOn ? "Turn Heater Off" : "Turn Heater On") { mug.isOn ? mug.turnOff() : mug.turnOn() }
            power.image = symbol("power", mug.isOn ? .systemOrange : nil)
            menu.addItem(power)
            let pause = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
            pause.image = symbol("pause.fill")
            pause.isEnabled = mug.isOn
            let pauses = NSMenu()
            for (title, minutes) in [("15 minutes", 15.0), ("30 minutes", 30), ("1 hour", 60)] {
                pauses.addItem(item(title) { mug.pause(minutes: minutes) })
            }
            pause.submenu = pauses
            menu.addItem(pause)
        }

        let programs = NSMenuItem(title: "Programs", action: nil, keyEquivalent: "")
        programs.image = symbol("list.bullet")
        let list = NSMenu()
        for p in mug.presets {
            let row = item(p.name) { mug.apply(p) }
            row.state = mug.isRunning(p) ? .on : .off
            row.toolTip = mug.modeDescription(p.mode)
            list.addItem(row)
        }
        programs.submenu = list
        programs.isEnabled = !mug.presets.isEmpty
        menu.addItem(programs)

        let reconnect = item("Reconnect") { mug.reconnect() }
        reconnect.image = symbol("arrow.clockwise")
        menu.addItem(reconnect)
        menu.addItem(.separator())

        let login = item("Open at Login") { mug.mugProblem = LoginItem.set(!LoginItem.isOn) }
        login.state = LoginItem.isOn ? .on : .off
        menu.addItem(login)
        menu.addItem(item("About Embarr") { AppActions.about() })
        let update = item(Updater.shared.menuTitle) { Updater.shared.menuAction() }
        update.isEnabled = Updater.shared.state != .installing && Updater.shared.state != .checking
        if Updater.shared.available != nil { update.image = symbol("arrow.down.circle.fill", .systemOrange) }
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(item("Quit Embarr", key: "q") { NSApp.terminate(nil) })
        return menu
    }
}

/// Lets an NSMenuItem run a closure.
@MainActor
private final class ClosureTarget: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run() { action() }
}

// MARK: - Updates

/// "Check for Updates…" (or "Install Update (1.9)…") in the popover's "…" menu.
struct UpdateMenuButton: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Button(updater.menuTitle) { updater.menuAction() }
            .disabled(updater.state == .installing || updater.state == .checking)
    }
}

/// Settings > General: the version, the last check, Check Now / Install Update, and the automatic-check switch.
struct UpdateRow: View {
    @ObservedObject private var updater = Updater.shared

    private var status: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .installing: return "Installing the update…"
        case .available: return "Version \(updater.available?.version?.description ?? "") is available."
        case .failed(let why): return "Last check failed: \(why)"
        case .idle, .upToDate:
            guard let last = updater.lastCheck else { return "Not checked yet." }
            return "Up to date. Checked \(last.formatted(.relative(presentation: .named)))."
        }
    }

    var body: some View {
        LabeledContent {
            if updater.available != nil {
                Button("Install Update") { updater.install() }.disabled(updater.state == .installing)
            } else {
                Button("Check Now") { Task { await updater.check(userAsked: true) } }.disabled(updater.state == .checking)
            }
        } label: {
            Text("Embarr \(updater.current.description)")
            Text(status)
        }
        Toggle("Check for updates automatically", isOn: $updater.automatic)
    }
}
