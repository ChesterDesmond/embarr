import Foundation

/// What the popover's power row remembers: the program Turn on goes back to, and when a pause ends.
/// Turn off and Pause both put the mug on `Mode.off`; this is how the app knows what to come back to.
public struct PowerMemory: Codable, Equatable, Sendable {
    /// The last program that heats (never `.off`). Nil before anything has been chosen.
    public private(set) var resumeMode: Mode?
    public private(set) var resumePresetID: UUID?
    /// While set and in the future, the heater is paused and comes back on by itself at this time.
    public private(set) var pausedUntil: Date?

    /// What Turn on returns to when nothing has been chosen yet: "Hot sip".
    public static let fallback = Mode.hold(45)

    public init() {}

    /// The user picked `mode` (a preset, the slider, an edited program). Any pause is over. A heating mode becomes
    /// what Turn on goes back to; `.off` ("Just let it cool") leaves that alone.
    public mutating func chose(_ mode: Mode, presetID: UUID?) {
        pausedUntil = nil
        if mode != .off {
            resumeMode = mode
            resumePresetID = presetID
        }
    }

    /// Heater off until `until`, then back to the remembered program. The caller switches the mode to `.off`.
    public mutating func pause(until: Date) { pausedUntil = until }

    /// "Stay off" during a pause: no coming back by itself. Turn on still knows the program.
    public mutating func endPause() { pausedUntil = nil }

    public func isPaused(now: Date) -> Bool { pausedUntil.map { now < $0 } ?? false }

    /// The power button while off: ends any pause and says what to go back to.
    public mutating func turnOn() -> (mode: Mode, presetID: UUID?) {
        pausedUntil = nil
        return (resumeMode ?? Self.fallback, resumePresetID)
    }

    /// How late a pause may still end by itself. Past this (the app was quit, or the Mac asleep, through the end of
    /// the pause, say overnight) the heater stays off rather than coming on unannounced at the next launch.
    public static let lateResumeLimit: TimeInterval = 30 * 60

    /// Once a pause has run out: what to go back to, exactly once. Nil while still paused, not paused at all, or
    /// when the pause ended more than `lateResumeLimit` ago (the pause is then dropped and the heater stays off).
    public mutating func dueResume(now: Date) -> (mode: Mode, presetID: UUID?)? {
        guard let until = pausedUntil, now >= until else { return nil }
        if now.timeIntervalSince(until) > Self.lateResumeLimit {
            pausedUntil = nil
            return nil
        }
        return turnOn()
    }

    /// What to actually run when coming back: the remembered program as it is now, since it may have been edited
    /// during the pause. A program deleted meanwhile comes back with its last settings, no longer tied to a preset.
    public static func current(_ back: (mode: Mode, presetID: UUID?), in presets: [Preset]) -> (mode: Mode, presetID: UUID?) {
        guard let id = back.presetID else { return back }
        if let p = presets.first(where: { $0.id == id }) { return (p.mode, id) }
        return (back.mode, nil)
    }
}
