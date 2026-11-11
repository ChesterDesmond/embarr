import Foundation

/// Decides when to ask "the mug is off the charger: heater on or off?", so Chester doesn't have to reach for the
/// button on the bottom of the mug.
///
/// The mug's battery characteristic says whether it sits on the charging coaster (python-ember-mug calls it
/// `on_charging_base`; it stays set at 100%). Lifting the mug for a sip clears it for a few seconds, so the
/// question waits until the mug has been off the charger for `delay`, and is asked once per
/// time off the charger. Putting it back withdraws the question.
public struct ChargerWatch: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Post the question. `heaterOn` picks the wording and the buttons.
        case ask(heaterOn: Bool)
        /// The mug is back on the charger (or the question no longer applies): remove it.
        case withdraw
    }

    /// How long the mug must be off the charger before asking. Long enough to drink from it and put it back.
    public static let delay: TimeInterval = 60

    private var offSince: Date?
    private var asked = false

    public init() {}

    /// Feed each reading. `onCharger` is nil when unknown (no battery reading yet, or the link is down), which
    /// changes nothing. The mug's own liquid state isn't consulted: it reads "Empty" when a cool drink goes in
    /// with the heater off (seen 2026-11-11), which is exactly when the question matters.
    public mutating func update(now: Date, onCharger: Bool?, heaterOn: Bool) -> Action? {
        guard let onCharger else { return nil }
        if onCharger {
            offSince = nil
            defer { asked = false }
            return asked ? .withdraw : nil
        }
        let since = offSince ?? now
        offSince = since
        guard !asked, now.timeIntervalSince(since) >= Self.delay else { return nil }
        asked = true
        return .ask(heaterOn: heaterOn)
    }

    /// The question was answered (or dismissed). It stays answered until the mug goes back on the charger.
    public mutating func answered() { asked = true }
}
