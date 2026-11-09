/// How the mug's battery is drawn: a color tier and an SF Symbol that fills with the charge.
public enum BatteryTier: Equatable, Sendable {
    /// Green: 50% and up, or charging.
    case good
    /// Yellow: 21–49%.
    case fair
    /// Red: 20% and below (the low-battery notification comes at 15%).
    case low
}

public extension EmberCodec.Battery {
    private var clamped: Int { min(max(percent, 0), 100) }

    var tier: BatteryTier {
        if charging || clamped >= 50 { return .good }
        return clamped > 20 ? .fair : .low
    }

    /// The nearest of SF Symbols' five battery fills, or the bolt while on the coaster.
    var symbolName: String {
        if charging { return "battery.100percent.bolt" }
        switch clamped {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
