import Foundation

/// Ember mugs seen while scanning, for the "Mugs nearby" list: each mug once, in the order they first showed up (so rows
/// don't jump under the pointer as signal strength wobbles), and a mug that hasn't been heard from in `staleAfter`
/// seconds drops off (it went to sleep or out of range).
public struct NearbyMugs: Sendable {
    public struct Mug: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var rssi: Int
        public var lastSeen: Date
        public var firstSeen: Date
    }

    public static let staleAfter: TimeInterval = 30
    private var mugs: [UUID: Mug] = [:]

    public init() {}

    /// An advertisement counts as a mug when its name starts with "Ember" (the factory names) or it advertises Ember's
    /// service. A mug renamed by its owner keeps the service but loses the prefix.
    public static func looksLikeEmber(name: String, advertisesEmberService: Bool) -> Bool {
        advertisesEmberService || name.hasPrefix("Ember")
    }

    /// Records an advertisement. Non-Ember names are ignored unless that device was already known as a mug.
    public mutating func saw(id: UUID, name: String, rssi: Int, at now: Date, advertisesEmberService: Bool = false) {
        guard mugs[id] != nil || Self.looksLikeEmber(name: name, advertisesEmberService: advertisesEmberService) else { return }
        mugs[id] = Mug(id: id, name: name.isEmpty ? "Ember mug" : name, rssi: rssi, lastSeen: now,
                       firstSeen: mugs[id]?.firstSeen ?? now)
    }

    public func list(now: Date) -> [Mug] {
        mugs.values.filter { now.timeIntervalSince($0.lastSeen) <= Self.staleAfter }
            .sorted { ($0.firstSeen, $0.id.uuidString) < ($1.firstSeen, $1.id.uuidString) }
    }

    public mutating func clear() { mugs = [:] }
}
