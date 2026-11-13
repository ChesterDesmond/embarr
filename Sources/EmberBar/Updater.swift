import AppKit
import CryptoKit
import EmberCore
import Foundation
import Security
import UserNotifications

/// Checks GitHub for a newer Embarr once a day and installs it in place: download the zip, check its SHA-256 against
/// the release's checksum file, check the new app is signed by the same certificate as this one (its designated
/// requirement), swap it into place and relaunch. A file the app downloads itself isn't quarantined, so an update
/// skips Gatekeeper's "Open Anyway" step, and the stable certificate keeps the Bluetooth permission.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "ChesterDesmond/embarr"
    static let notificationID = "update"
    static let installAction = "install-update"
    static let category = UNNotificationCategory(identifier: "update", actions: [
        UNNotificationAction(identifier: installAction, title: "Install Update"),
    ], intentIdentifiers: [])

    enum State: Equatable {
        case idle, checking, upToDate, available, installing
        case failed(String)
    }

    /// GitHub's latest-release API. For testing an update end to end against a local server: EMBARR_UPDATE_FEED
    /// points it at another URL serving the same JSON, and EMBARR_UPDATE_INSTALL=1 installs what the automatic check
    /// finds without asking.
    static var feed: URL {
        ProcessInfo.processInfo.environment["EMBARR_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var available: Release?
    @Published private(set) var lastCheck: Date?
    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "updates.automatic"); if automatic { checkIfDue() } }
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    let current = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!

    private init() {
        automatic = defaults.object(forKey: "updates.automatic") as? Bool ?? true
        lastCheck = defaults.object(forKey: "updates.lastCheck") as? Date
    }

    /// Starts the daily check. Called once at launch.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard automatic, state != .checking, state != .installing,
              UpdateSchedule.isDue(lastCheck: lastCheck, now: Date()) else { return }
        Task { await check(userAsked: false) }
    }

    /// Asks GitHub for the latest release. When the user asked, the answer is shown in a dialog either way.
    func check(userAsked: Bool) async {
        state = .checking
        do {
            var request = URLRequest(url: Self.feed)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Embarr/\(current)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastCheck = Date(); defaults.set(lastCheck, forKey: "updates.lastCheck")
            if release.isUpdate(over: current) {
                available = release; state = .available
                if userAsked { offer(release) }
                else if ProcessInfo.processInfo.environment["EMBARR_UPDATE_INSTALL"] == "1" { install() }  // testing aid
                else { notifyOnce(release) }
            } else {
                available = nil; state = .upToDate
                if userAsked { alert("Embarr is up to date", "You have the latest version, \(current).") }
            }
        } catch {
            state = .failed(error.localizedDescription)
            if userAsked { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// A notification once per new version, with an Install Update button.
    private func notifyOnce(_ release: Release) {
        guard let v = release.version, defaults.string(forKey: "updates.notified") != v.description else { return }
        defaults.set(v.description, forKey: "updates.notified")
        let content = UNMutableNotificationContent()
        content.title = "Embarr \(v) is available"
        content.body = "You have \(current). Install it now, or later from the menu-bar icon's menu."
        content.categoryIdentifier = Self.category.identifier
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    /// The "Embarr 1.9 is available" dialog with the release notes, Install Update and Later.
    func offer(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Embarr \(release.version?.description ?? release.tag) is available"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "You have \(current)." + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(1200)))
        a.addButton(withTitle: "Install Update")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { install() }
    }

    /// Installs the available update, then relaunches. Any failure leaves the current app as it was.
    func install() {
        guard let release = available, state != .installing else { return }
        state = .installing
        Task {
            do {
                try await Self.download(release, replacing: Bundle.main.bundleURL)
                Self.relaunch(Bundle.main.bundleURL)
            } catch {
                state = .failed(error.localizedDescription)
                FileHandle.standardError.write(Data("update failed: \(error.localizedDescription)\n".utf8))
                alert("Couldn't install the update", error.localizedDescription + "\n\nYou can download it from \(release.page.absoluteString)")
            }
        }
    }

    private nonisolated static func download(_ release: Release, replacing app: URL) async throws {
        guard let zip = release.zip, let sum = release.checksum else { throw UpdateError("The release has no app to download.") }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError("Embarr can't replace itself in \(folder.path). Move it to your Applications folder and try again.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("embarr-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let (sumData, _) = try await URLSession.shared.data(from: sum.url)
        guard let expected = Checksum.parse(String(decoding: sumData, as: UTF8.self)) else { throw UpdateError("The checksum file couldn't be read.") }
        let (downloaded, _) = try await URLSession.shared.download(from: zip.url)
        let zipFile = work.appendingPathComponent(zip.name)
        try FileManager.default.moveItem(at: downloaded, to: zipFile)
        let actual = SHA256.hash(data: try Data(contentsOf: zipFile)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError("The download didn't match its checksum, so it wasn't installed.") }

        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.appendingPathComponent("unzipped").path])
        guard let enumerator = FileManager.default.enumerator(at: work.appendingPathComponent("unzipped"), includingPropertiesForKeys: nil),
              let newApp = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "Embarr.app" }) else {
            throw UpdateError("The download has no Embarr.app in it.")
        }
        try verifySameSigner(newApp)
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        _ = try FileManager.default.replaceItemAt(app, withItemAt: newApp)
    }

    /// The new app must satisfy this app's designated requirement: same bundle ID, signed by the same certificate.
    private nonisolated static func verifySameSigner(_ newApp: URL) throws {
        var me: SecCode?, requirement: SecRequirement?, staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError("Couldn't read the app's signature.")
        }
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else {
            throw UpdateError("The download isn't signed the same way as this copy of Embarr (error \(status)), so it wasn't installed.")
        }
    }

    private nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus)).") }
    }

    /// Opens the new copy a moment after this one quits.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// The menu item for both menus: "Install Update (1.9)…" when one is waiting, else "Check for Updates…".
    var menuTitle: String {
        if let v = available?.version { return "Install Update (\(v))…" }
        return "Check for Updates…"
    }

    func menuAction() {
        if let available { offer(available) } else { Task { await check(userAsked: true) } }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
