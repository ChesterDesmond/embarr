import Foundation

/// One leg of a glide: hold `target` for `minutes`, or until the mug is empty when `minutes` is nil.
public struct GlideStep: Codable, Equatable, Hashable, Sendable {
    public var target: Double
    public var minutes: Double?
    public init(target: Double, minutes: Double?) { self.target = target; self.minutes = minutes }
}

public enum Mode: Codable, Equatable, Hashable, Sendable {
    /// Heater off. The coffee cools on its own.
    case off
    /// Keep the coffee at one temperature. At or above the mug's floor the mug does it natively;
    /// below the floor the app pulses the heater.
    case hold(Double)
    /// A schedule of targets counted from the moment the mug is filled.
    case glide([GlideStep])

    public var summary: String {
        switch self {
        case .off: "Heater off"
        case .hold: "Hold"
        case .glide: "Glide"
        }
    }
}

public struct Preset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: Mode
    public init(id: UUID = UUID(), name: String, mode: Mode) { self.id = id; self.name = name; self.mode = mode }

    public static let defaults: [Preset] = [
        Preset(name: "Body temp", mode: .hold(37)),
        Preset(name: "Warm sip", mode: .hold(41)),
        Preset(name: "Mug floor", mode: .hold(45)),
        Preset(name: "Specialty glide", mode: .glide([
            GlideStep(target: 45, minutes: 10),
            GlideStep(target: 41, minutes: 10),
            GlideStep(target: 37, minutes: nil),
        ])),
        Preset(name: "Just let it cool", mode: .off),
    ]
}

public enum ControllerEvent: Equatable, Sendable {
    /// The coffee has come down to the current target for the first time since it was poured.
    case ready(target: Double)
    case filled
    case emptied
}

public struct ControllerOutput: Equatable, Sendable {
    /// What to write to the mug's target characteristic, or nil to leave it alone.
    public var heaterTarget: Double?
    /// The target the app is steering toward (nil when the heater is simply off).
    public var goal: Double?
    public var pulsing: Bool
    public var events: [ControllerEvent]
}

/// Steers the mug toward temperatures its firmware will not hold by switching the heater between
/// off (target 0) and the floor (45 C). Pure logic: no Bluetooth, no clock of its own.
public struct HeaterController: Codable, Equatable, Sendable {
    /// How far below the goal the coffee may fall before the heater comes on.
    public var band: Double = 0.8
    /// Learned: how far the reading keeps rising after the heater is switched off.
    public var overshoot: Double = 1.0
    /// Shortest gap between heater-on pulses, so the mug is not flipped every few seconds.
    public var minOnInterval: TimeInterval = 20
    /// How long after a cutoff to watch for the peak before learning from it.
    public var learnWindow: TimeInterval = 120

    public private(set) var pulsing = false
    public private(set) var fillStart: Date?
    var lastOnAt: Date?
    var cutoffAt: Date?
    var cutoffTemp: Double?
    var peakAfterCutoff: Double?
    var announcedReady = false
    var hadLiquid = false

    public init() {}

    /// Forget the current fill's progress (used when the mode changes).
    public mutating func resetForNewMode(now: Date) {
        pulsing = false
        announcedReady = false
        lastOnAt = nil
        cutoffAt = nil
        if hadLiquid { fillStart = now }
    }

    public func goal(for mode: Mode, now: Date) -> Double? {
        switch mode {
        case .off: return nil
        case .hold(let t): return t
        case .glide(let steps):
            guard !steps.isEmpty else { return nil }
            var remaining = now.timeIntervalSince(fillStart ?? now) / 60
            for step in steps {
                guard let m = step.minutes else { return step.target }
                if remaining < m { return step.target }
                remaining -= m
            }
            return steps.last!.target
        }
    }

    public mutating func update(now: Date, temp: Double?, state: LiquidState, mode: Mode) -> ControllerOutput {
        var events: [ControllerEvent] = []
        if state == .unknown || temp == nil {
            return ControllerOutput(heaterTarget: nil, goal: goal(for: mode, now: now), pulsing: pulsing, events: [])
        }
        let temp = temp!

        if state.hasLiquid && !hadLiquid {
            fillStart = now
            announcedReady = false
            pulsing = false
            lastOnAt = nil
            cutoffAt = nil
            events.append(.filled)
        } else if !state.hasLiquid && hadLiquid {
            events.append(.emptied)
        }
        hadLiquid = state.hasLiquid

        let goal = goal(for: mode, now: now)

        guard let g = goal else {
            pulsing = false
            return ControllerOutput(heaterTarget: MugLimits.off, goal: nil, pulsing: false, events: events)
        }

        if state.hasLiquid && !announcedReady && temp <= g + 0.5 {
            announcedReady = true
            events.append(.ready(target: g))
        }

        if g >= MugLimits.floor {
            pulsing = false
            let native = min(max(g, MugLimits.floor), MugLimits.ceiling)
            return ControllerOutput(heaterTarget: native, goal: g, pulsing: false, events: events)
        }

        guard state.hasLiquid else {
            pulsing = false
            return ControllerOutput(heaterTarget: MugLimits.off, goal: g, pulsing: false, events: events)
        }

        learn(now: now, temp: temp)

        let cutoff = g - overshoot
        let turnOn = g - max(band, overshoot + 0.3)
        if pulsing {
            if temp >= cutoff {
                pulsing = false
                cutoffAt = now
                cutoffTemp = temp
                peakAfterCutoff = temp
            }
        } else if temp <= turnOn, lastOnAt.map({ now.timeIntervalSince($0) >= minOnInterval }) ?? true {
            pulsing = true
            lastOnAt = now
        }
        return ControllerOutput(heaterTarget: pulsing ? MugLimits.floor : MugLimits.off,
                                goal: g, pulsing: pulsing, events: events)
    }

    private mutating func learn(now: Date, temp: Double) {
        guard let at = cutoffAt, let from = cutoffTemp else { return }
        if now.timeIntervalSince(at) <= learnWindow, !pulsing {
            peakAfterCutoff = max(peakAfterCutoff ?? temp, temp)
            return
        }
        let rise = (peakAfterCutoff ?? from) - from
        overshoot = min(4, max(0.2, 0.7 * overshoot + 0.3 * rise))
        cutoffAt = nil
        cutoffTemp = nil
        peakAfterCutoff = nil
    }
}
