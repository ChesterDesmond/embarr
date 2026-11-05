import Foundation

/// The program editor's Hold / Glide / Off switch. Switching keeps what it can: a hold becomes a one-step glide at
/// the same temperature, and a glide becomes a hold at its first step.
public enum ProgramKind: CaseIterable, Sendable {
    case hold, glide, off

    public init(_ mode: Mode) {
        switch mode {
        case .hold: self = .hold
        case .glide: self = .glide
        case .off: self = .off
        }
    }

    public var label: String {
        switch self {
        case .hold: "Hold"
        case .glide: "Glide"
        case .off: "Heater off"
        }
    }

    /// Where a hold or glide starts when there's nothing to keep: 45 C, "Hot sip".
    static let defaultStart = 45.0

    public func convert(_ mode: Mode) -> Mode {
        let start: Double = switch mode {
        case .hold(let t): t
        case .glide(let steps): steps.first?.target ?? Self.defaultStart
        case .off: Self.defaultStart
        }
        switch self {
        case .hold: if case .hold = mode { return mode }; return .hold(start)
        case .glide:
            if case .glide = mode { return mode }
            return .glide([GlideStep(target: start, minutes: 10), GlideStep(target: max(MugLimits.sliderFloor, start - 4), minutes: nil)])
        case .off: return .off
        }
    }
}
