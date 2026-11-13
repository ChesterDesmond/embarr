import Foundation

/// A dotted version number ("1.8", "v1.10.2"), compared part by part: 1.10 is newer than 1.9.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A release as GitHub's "latest release" API returns it: only the fields the updater reads.
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let url: URL
        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
        public init(name: String, url: URL) { self.name = name; self.url = url }
    }

    public let tag: String
    public let notes: String
    public let page: URL
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tag = "tag_name", notes = "body", page = "html_url", assets }

    public init(tag: String, notes: String, page: URL, assets: [Asset]) {
        self.tag = tag; self.notes = notes; self.page = page; self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        page = try c.decode(URL.self, forKey: .page)
        assets = try c.decode([Asset].self, forKey: .assets)
    }

    public var version: AppVersion? { AppVersion(tag) }

    /// The app's zip ("Embarr-1.8.zip") and its checksum file ("Embarr-1.8.zip.sha256"). An update needs both.
    public var zip: Asset? { assets.first { $0.name.hasPrefix("Embarr-") && $0.name.hasSuffix(".zip") } }
    public var checksum: Asset? { zip.flatMap { z in assets.first { $0.name == z.name + ".sha256" } } }

    /// Whether this release is an update for a copy running `current`: newer, and with a zip and checksum to install.
    public func isUpdate(over current: AppVersion) -> Bool {
        guard let v = version, zip != nil, checksum != nil else { return false }
        return v > current
    }
}

public enum Checksum {
    /// The SHA-256 in a checksum file, as `shasum -a 256` writes it ("<64 hex>  <file name>"), lowercased.
    public static func parse(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }
}

/// When the automatic check runs: at most once a day.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 3600

    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now  // a clock set back counts as due
    }
}
