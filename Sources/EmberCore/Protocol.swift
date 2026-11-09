import Foundation

/// The Ember mug's Bluetooth protocol, as read off Chester's Ember Cup 2 on 2026-11-05
/// (firmware 120, hardware 12) and cross-checked against python-ember-mug.
public enum EmberUUID {
    public static let service = "FC543622-236C-4C94-8FA9-944A3E5353FA"
    public static func characteristic(_ n: Int) -> String {
        String(format: "FC54%04X-236C-4C94-8FA9-944A3E5353FA", n)
    }
    /// Whether a service UUID is one of Ember's: FC54xxxx-236C-4C94-8FA9-944A3E5353FA. The Cup and Mug 2 use
    /// FC543622; python-ember-mug lists FC543621 and FC5421A1 for travel mugs.
    public static func isEmberService(_ uuid: String) -> Bool {
        let u = uuid.uppercased()
        return u.count == 36 && u.hasPrefix("FC54") && u.hasSuffix("-236C-4C94-8FA9-944A3E5353FA")
    }
    public static let mugName = characteristic(0x01)       // read/write, ASCII, up to 14 characters
    public static let currentTemp = characteristic(0x02)   // read, uint16 LE, 0.01 C
    public static let targetTemp = characteristic(0x03)    // read/write, uint16 LE, 0.01 C; 0 = heater off
    public static let unit = characteristic(0x04)          // read/write, 0 = C, 1 = F
    public static let liquidLevel = characteristic(0x05)   // read, 0...30
    public static let battery = characteristic(0x07)       // read, [percent, charging, ...]
    public static let liquidState = characteristic(0x08)   // read
    public static let firmware = characteristic(0x0C)      // read, 3 x uint16 LE
    public static let pushEvents = characteristic(0x12)    // notify
    public static let ledColor = characteristic(0x14)      // read/write, RGBA
}

public enum MugLimits {
    /// Lowest target value the firmware accepts (measured: 45.0 kept, 44.5 and below reset to 48.88).
    /// The app writes it to switch the heater on during pulses. Accepting it is not holding it: see `lowestHeld`.
    public static let pulseOn = 45.0
    /// Lowest temperature the mug actually holds by itself (120 F). Measured 2026-11-05 with coffee in the
    /// mug: target 45.00 read back as 45.00, yet the mug reported "Holding" at 48.89 for two hours.
    /// Any goal below this is reached by pulsing.
    public static let lowestHeld = 48.89
    /// Whether Embarr has to pulse the heater to reach `goal`, because the mug won't hold it by itself.
    /// The 0.01 slack keeps 120 F (48.8889 C, a whole-degree Fahrenheit slider stop) with the mug.
    public static func needsPulsing(_ goal: Double) -> Bool { goal < lowestHeld - 0.01 }
    /// Bottom of the temperature sliders (86 F).
    public static let sliderFloor = 30.0
    /// Highest target the app offers (145 F).
    public static let ceiling = 62.5
    /// Value that turns the heater off.
    public static let off = 0.0
}

public enum LiquidState: UInt8, Codable, Sendable {
    case unknown = 0, empty = 1, filling = 2, coldNoControl = 3, cooling = 4, heating = 5, holding = 6, warmNoControl = 7

    public var label: String {
        switch self {
        case .unknown: "Unknown"
        case .empty: "Empty"
        case .filling: "Filling"
        case .coldNoControl: "Cold"
        case .cooling: "Cooling"
        case .heating: "Heating"
        case .holding: "Holding"
        case .warmNoControl: "Warm"
        }
    }

    public var hasLiquid: Bool { self != .empty && self != .unknown }
}

public enum EmberCodec {
    public static func decodeTemp(_ data: Data) -> Double? {
        guard data.count >= 2 else { return nil }
        let raw = UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
        return Double(raw) / 100
    }

    public static func encodeTemp(_ celsius: Double) -> Data {
        let raw = UInt16(max(0, min(Double(UInt16.max), (celsius * 100).rounded())))
        return Data([UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }

    public struct Battery: Equatable, Sendable {
        public var percent: Int
        public var charging: Bool
        public init(percent: Int, charging: Bool) { self.percent = percent; self.charging = charging }
    }

    public static func decodeBattery(_ data: Data) -> Battery? {
        guard data.count >= 2 else { return nil }
        return Battery(percent: Int(data[data.startIndex]), charging: data[data.startIndex + 1] != 0)
    }

    public static func decodeLiquidState(_ data: Data) -> LiquidState {
        guard let b = data.first else { return .unknown }
        return LiquidState(rawValue: b) ?? .unknown
    }

    public static func decodeFirmware(_ data: Data) -> String? {
        guard data.count >= 6 else { return nil }
        func u16(_ i: Int) -> Int { Int(data[data.startIndex + i]) | Int(data[data.startIndex + i + 1]) << 8 }
        return "firmware \(u16(0)), hardware \(u16(2))"
    }

    public struct RGB: Equatable, Hashable, Codable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    }

    public static func decodeLED(_ data: Data) -> RGB? {
        guard data.count >= 3 else { return nil }
        let s = data.startIndex
        return RGB(r: data[s], g: data[s + 1], b: data[s + 2])
    }

    public static func encodeLED(_ c: RGB) -> Data { Data([c.r, c.g, c.b, 0xFF]) }

    /// Longest name the mug stores (python-ember-mug's limit).
    public static let maxNameLength = 14
    /// Characters a mug name may use: plain letters, digits, spaces and a little punctuation. Kept conservative
    /// because the firmware's own rules aren't documented.
    static let namePunctuation = "-_.,'!&()"
    static let nameCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 " + namePunctuation)
    /// What a mug name may be, for the rename box.
    public static var nameHint: String {
        "Up to \(maxNameLength) characters: letters, numbers, spaces and " + namePunctuation.map(String.init).joined(separator: " ")
    }

    /// The bytes to write to rename the mug, or nil if the mug couldn't take this name.
    public static func encodeName(_ name: String) -> Data? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength,
              trimmed.unicodeScalars.allSatisfy(nameCharacters.contains) else { return nil }
        return Data(trimmed.utf8)
    }

    public static func decodeName(_ data: Data) -> String? {
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

extension EmberCodec.RGB {
    /// The same hue at `fraction` of the brightness (used for the slow blink).
    public func dimmed(_ fraction: Double) -> Self {
        func f(_ v: UInt8) -> UInt8 { UInt8((Double(v) * fraction).rounded()) }
        return .init(r: f(r), g: f(g), b: f(b))
    }
}

public enum TempUnit: String, Codable, CaseIterable, Sendable {
    case celsius = "C", fahrenheit = "F"

    public func display(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    public func toCelsius(_ value: Double) -> Double {
        self == .celsius ? value : (value - 32) * 5 / 9
    }

    public func format(_ celsius: Double?, decimals: Int = 0) -> String {
        guard let c = celsius else { return "--°" }
        return String(format: "%.\(decimals)f°", display(c))
    }

    /// Both scales, this unit first: "113°F / 45°C".
    public func dual(_ celsius: Double) -> String {
        let other: TempUnit = self == .celsius ? .fahrenheit : .celsius
        return "\(format(celsius))\(rawValue) / \(other.format(celsius))\(other.rawValue)"
    }
}
