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
    /// Keep the coffee at one temperature. At or above `MugLimits.lowestHeld` the mug does it natively;
    /// below it the app pulses the heater.
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

    /// True when Ember Bar cycles the heater for at least part of this mode: a hold below what the mug holds by
    /// itself, or a glide with any such step.
    public var isCycling: Bool {
        switch self {
        case .off: false
        case .hold(let t): MugLimits.needsPulsing(t)
        case .glide(let steps): steps.contains { MugLimits.needsPulsing($0.target) }
        }
    }
}

public struct Preset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: Mode
    /// Optional mug light color while this preset is active; nil keeps the mug's everyday color.
    public var light: EmberCodec.RGB?
    public init(id: UUID = UUID(), name: String, mode: Mode, light: EmberCodec.RGB? = nil) {
        self.id = id; self.name = name; self.mode = mode; self.light = light
    }

    public static let defaults: [Preset] = [
        Preset(name: "Body temp", mode: .hold(37)),
        Preset(name: "Warm sip", mode: .hold(41)),
        Preset(name: "Hot sip", mode: .hold(45)),
        Preset(name: "Specialty glide", mode: .glide([
            GlideStep(target: 45, minutes: 10),
            GlideStep(target: 41, minutes: 10),
            GlideStep(target: 37, minutes: nil),
        ])),
        Preset(name: "Just let it cool", mode: .off),
    ]
}

public enum ControllerEvent: Equatable, Sendable {
    /// The coffee has reached the current target (cooled down to it, or warmed up to it) for the first time since
    /// it was poured or the mode changed.
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
/// off (target 0) and on (`MugLimits.pulseOn`). Pure logic: no Bluetooth, no clock of its own.
public struct HeaterController: Codable, Equatable, Sendable {
    /// How far below the goal the coffee may fall before the heater comes on.
    public var band: Double = 0.8
    /// Learned: how far the reading keeps rising after the heater is switched off.
    public var overshoot: Double = 1.0
    /// Shortest gap between heater-on pulses, so the mug is not flipped every few seconds.
    public var minOnInterval: TimeInterval = 20
    /// Longest to watch for the peak after a cutoff. No new burst starts until the peak is in (the reading has
    /// turned down, fallen below the cutoff reading without rising, or this window ran out), so each burst's rise
    /// is measured on its own.
    public var learnWindow: TimeInterval = 120
    /// The reading has peaked once it rose at least this much after the cutoff and then fell this far below its
    /// high, or fell this far below the cutoff reading without rising; either no sooner than `minPeakWatch` after
    /// the cutoff. A burst that heats shows within seconds (the 30 s burst read +1.1 C 6 s after cutoff, then
    /// peaked a minute later), so a reading still falling at 30 s means the burst did not lift it.
    static let peakDrop = 0.3
    static let minPeakWatch: TimeInterval = 30
    /// Longest a single burst runs. The mug's sensor lags the heater, then spikes: on 2026-11-05 a 30 s burst read
    /// 39.5 -> 40.0 C while on, then peaked at 53.3 C a minute after cutoff.
    public var maxOnDuration: TimeInterval = 8
    /// How long after a pour the sensor needs to catch up (it read 32.78 C as hot coffee went in).
    public static let settleAfterFill: TimeInterval = 60
    /// A cup found after Ember Bar was out of touch (quit, or out of range) for longer than this, at least
    /// `refillRise` hotter than the last settled reading, and hotter than the mug's own heater ever takes it
    /// (`lowestHeld` + `refillRise`), is a new cup: emptied and refilled meanwhile. A cup that only cooled while the
    /// lid was closed, or was warmed by a burst still running when the link dropped, is still the same cup.
    public static let awayForNewCup: TimeInterval = 15 * 60
    public static let refillRise = 3.0

    public private(set) var pulsing = false
    public private(set) var fillStart: Date?
    var lastOnAt: Date?
    var cutoffAt: Date?
    /// A burst was running (or still peaking) when the link dropped: wait for its peak, learn nothing from it.
    var burstInterrupted = false
    var learnFromCutoff = true
    var cutoffTemp: Double?
    var peakAfterCutoff: Double?
    var announcedReady = false
    /// The coffee has read above the goal since the pour or mode change, so "ready" means it came down to it.
    var sawAboveGoal = false
    var hadLiquid = false
    /// Set when loaded from disk or after the Bluetooth link drops: the first reading after the gap decides whether
    /// the cup in the mug is still the one poured at `fillStart`.
    var restored = false
    /// When the last real reading came in, and what it was; saved, so a relaunch can tell how long Ember Bar was
    /// away and whether the coffee was replaced meanwhile.
    var lastSeen: Date?
    var lastTemp: Double?

    public init() {}

    /// The link dropped: the mug may have been emptied and refilled out of range. A burst that was on kept going
    /// out of our hands, so on the first reading back it is treated as just cut off: the next burst still waits
    /// for its peak, but nothing is learned from a cutoff we never saw.
    public mutating func lostContact() {
        restored = true
        if pulsing || cutoffAt != nil { burstInterrupted = true }
        pulsing = false
        cutoffAt = nil
        cutoffTemp = nil
        peakAfterCutoff = nil
    }

    // Saved: what the user set (band), what was learned (overshoot), and when the current cup was poured so a
    // relaunch mid-cup doesn't restart a glide, plus the last reading (time and value) to spot a refill made
    // while Ember Bar was away. The timing values (minOnInterval, learnWindow, maxOnDuration) are not saved, so
    // a new build's defaults always apply; they stay vars only so tests can set them. Every key is optional: a missing one never wipes the rest (synthesized Codable throws
    // on any missing key, and the caller then falls back to defaults).
    enum CodingKeys: String, CodingKey { case band, overshoot, tuning, fillStart, hadLiquid, lastSeen, lastTemp }

    /// Bump when the burst shape changes enough that a learned overshoot no longer applies.
    /// 1 (no key): uncapped 30 s bursts. 2: bursts capped at `maxOnDuration`.
    static let tuning = 2

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeaterController()
        band = try c.decodeIfPresent(Double.self, forKey: .band) ?? d.band
        let current = (try c.decodeIfPresent(Int.self, forKey: .tuning) ?? 1) == Self.tuning
        overshoot = current ? try c.decodeIfPresent(Double.self, forKey: .overshoot) ?? d.overshoot : d.overshoot
        fillStart = try c.decodeIfPresent(Date.self, forKey: .fillStart)
        hadLiquid = try c.decodeIfPresent(Bool.self, forKey: .hadLiquid) ?? false
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        lastTemp = try c.decodeIfPresent(Double.self, forKey: .lastTemp)
        announcedReady = hadLiquid  // don't re-announce a cup that was already in the mug before the relaunch
        restored = true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(band, forKey: .band)
        try c.encode(overshoot, forKey: .overshoot)
        try c.encode(Self.tuning, forKey: .tuning)
        try c.encodeIfPresent(fillStart, forKey: .fillStart)
        try c.encode(hadLiquid, forKey: .hadLiquid)
        try c.encodeIfPresent(lastSeen, forKey: .lastSeen)
        try c.encodeIfPresent(lastTemp, forKey: .lastTemp)
    }

    /// Forget the current fill's progress (used when the mode changes). `keepCupClock` is for coming back from Off
    /// or a pause: a glide carries on where the clock says (the coffee cooled meanwhile) instead of starting over.
    public mutating func resetForNewMode(now: Date, keepCupClock: Bool = false) {
        pulsing = false
        announcedReady = false
        sawAboveGoal = false
        lastOnAt = nil
        cutoffAt = nil
        if hadLiquid && !keepCupClock { fillStart = now }
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

        // Only on the first settled reading after a relaunch or reconnect, judged by how long Ember Bar was away (not
        // by the cup's age) and by whether the coffee came back hot: see `awayForNewCup`.
        // Mid-pour the sensor still reads low (32.78 C as hot coffee went in), so hold the decision until it's done.
        var staleCup = false
        if !(restored && state == .filling) {
            let away = lastSeen.map { now.timeIntervalSince($0) } ?? 0  // unknown (saved before lastSeen existed): keep the cup
            let refilled = lastTemp.map { temp >= max($0, MugLimits.lowestHeld) + Self.refillRise } ?? false
            staleCup = restored && hadLiquid && away > Self.awayForNewCup && refilled
            restored = false
            lastSeen = now
            if state != .filling { lastTemp = temp }  // mid-pour readings lag low
        }
        if state.hasLiquid && (!hadLiquid || staleCup) {
            fillStart = now
            restored = false  // this pour settles the "same cup?" question
            announcedReady = false
            sawAboveGoal = false
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

        // Ready = the coffee came down to the goal, or warmed up to it, once the sensor has caught up with the pour.
        let settled = state != .filling && now.timeIntervalSince(fillStart ?? now) >= Self.settleAfterFill
        if settled && temp > g + 0.5 { sawAboveGoal = true }
        // Coming down it may land a little under the goal between samples, but not far: coffee found cold after a
        // gap is not "ready".
        let atGoal = temp <= g + 0.5 && temp >= g - (sawAboveGoal ? 2 : 0.5)
        if state.hasLiquid && settled && atGoal && !announcedReady {
            announcedReady = true
            events.append(.ready(target: g))
        }

        if !MugLimits.needsPulsing(g) {
            pulsing = false
            let native = min(g, MugLimits.ceiling)
            return ControllerOutput(heaterTarget: native, goal: g, pulsing: false, events: events)
        }

        guard state.hasLiquid else {
            pulsing = false
            return ControllerOutput(heaterTarget: MugLimits.off, goal: g, pulsing: false, events: events)
        }

        if burstInterrupted {
            burstInterrupted = false
            cutoffAt = now
            cutoffTemp = temp
            peakAfterCutoff = temp
            learnFromCutoff = false
        }
        learn(now: now, temp: temp)

        let cutoff = g - overshoot
        let turnOn = swing(around: g).low
        if pulsing {
            if temp >= cutoff || lastOnAt.map({ now.timeIntervalSince($0) >= maxOnDuration }) ?? false {
                pulsing = false
                cutoffAt = now
                cutoffTemp = temp
                peakAfterCutoff = temp
                learnFromCutoff = true
            }
        } else if temp <= turnOn, cutoffAt == nil, lastOnAt.map({ now.timeIntervalSince($0) >= minOnInterval }) ?? true {
            pulsing = true
            lastOnAt = now
        }
        return ControllerOutput(heaterTarget: pulsing ? MugLimits.pulseOn : MugLimits.off,
                                goal: g, pulsing: pulsing, events: events)
    }

    /// Where pulsed coffee wanders: the heater comes on at `low`, and the burst plus its overshoot tops out near the goal.
    public func swing(around goal: Double) -> (low: Double, high: Double) {
        (goal - max(band, overshoot + 0.3), goal)
    }

    /// Rough average coffee temperature a mode aims for. A pulsed goal averages the middle of its swing; a glide
    /// weighs each step by its minutes over a `cupMinutes` cup, the last step taking whatever time is left.
    public func approxAverage(_ mode: Mode, cupMinutes: Double = 30) -> Double? {
        func level(_ g: Double) -> Double {
            guard MugLimits.needsPulsing(g) else { return g }
            let s = swing(around: g)
            return (s.low + s.high) / 2
        }
        switch mode {
        case .off: return nil
        case .hold(let t): return level(t)
        case .glide(let steps):
            guard let last = steps.last else { return nil }
            var left = cupMinutes, sum = 0.0
            for step in steps where left > 0 {
                let m = min(step.minutes ?? left, left)
                sum += level(step.target) * m
                left -= m
            }
            sum += level(last.target) * left
            return sum / cupMinutes
        }
    }

    private mutating func learn(now: Date, temp: Double) {
        guard let at = cutoffAt, let from = cutoffTemp else { return }
        let elapsed = now.timeIntervalSince(at)
        if elapsed <= learnWindow {
            let peak = max(peakAfterCutoff ?? temp, temp)
            peakAfterCutoff = peak
            let watched = elapsed >= Self.minPeakWatch
            let turnedDown = watched && peak - from >= Self.peakDrop && temp <= peak - Self.peakDrop
            // A burst too weak to lift the reading: it keeps falling below the cutoff, so stop waiting.
            let neverRose = watched && temp <= from - Self.peakDrop
            if !turnedDown && !neverRose { return }
        }
        let rise = (peakAfterCutoff ?? from) - from
        if learnFromCutoff { overshoot = min(4, max(0.2, 0.7 * overshoot + 0.3 * rise)) }
        cutoffAt = nil
        cutoffTemp = nil
        peakAfterCutoff = nil
    }
}

/// What the heater is doing right now, in the terms the menu-bar icon shows.
public enum HeaterPhase: Equatable, Sendable {
    /// Not connected, or nothing in the mug.
    case unavailable
    /// The heater is on (a pulse, or the mug's own heating).
    case heating
    /// The mug is holding its target by itself.
    case holding
    /// Heater off while hot coffee comes down to the goal.
    case coolingToGoal
    /// At the goal, heater off between pulses.
    case resting
    /// No goal at all: "Just let it cool".
    case heaterOff

    public init(connected: Bool, state: LiquidState, temp: Double?, goal: Double?, pulsing: Bool) {
        if !connected || !state.hasLiquid { self = .unavailable }
        else if pulsing || state == .heating { self = .heating }
        else if let g = goal {
            if let t = temp, t > g + 0.5 { self = .coolingToGoal }
            else { self = MugLimits.needsPulsing(g) ? .resting : .holding }
        } else { self = .heaterOff }
    }
}

/// The mug's light: a preset's own color, slowly blinking (full, then dim) while Ember Bar cycles the heater.
public enum MugLight {
    public static let dimFraction = 0.15

    /// `tick` advances once per blink half-period; odd ticks are the dim half.
    public static func color(base: EmberCodec.RGB, blinking: Bool, tick: Int) -> EmberCodec.RGB {
        blinking && tick % 2 == 1 ? base.dimmed(dimFraction) : base
    }
}
