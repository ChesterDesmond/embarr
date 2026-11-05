import Foundation

/// Colors for temperatures on the sliders: blue for cool, teal for lukewarm, amber where the mug starts holding by
/// itself (120 F), then orange and red up to the ceiling (145 F). Linear blend between stops, clamped at the ends.
public enum TempColor {
    public struct Stop: Equatable, Sendable {
        public let celsius: Double
        public let rgb: EmberCodec.RGB
    }

    public static let stops: [Stop] = [
        Stop(celsius: MugLimits.sliderFloor, rgb: .init(r: 50, g: 120, b: 230)),               // 86 F
        Stop(celsius: 40, rgb: .init(r: 0, g: 175, b: 170)),                // 104 F
        Stop(celsius: MugLimits.lowestHeld, rgb: .init(r: 240, g: 175, b: 0)), // 120 F
        Stop(celsius: 55, rgb: .init(r: 245, g: 120, b: 0)),                // 131 F
        Stop(celsius: MugLimits.ceiling, rgb: .init(r: 215, g: 40, b: 30)),  // 145 F
    ]

    public static func rgb(_ celsius: Double) -> EmberCodec.RGB {
        guard let first = stops.first, let last = stops.last, celsius.isFinite else { return stops.first?.rgb ?? .init(r: 0, g: 0, b: 0) }
        if celsius <= first.celsius { return first.rgb }
        if celsius >= last.celsius { return last.rgb }
        let i = stops.firstIndex { $0.celsius >= celsius }!
        let a = stops[i - 1], b = stops[i]
        let f = (celsius - a.celsius) / (b.celsius - a.celsius)
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * f).rounded()) }
        return .init(r: mix(a.rgb.r, b.rgb.r), g: mix(a.rgb.g, b.rgb.g), b: mix(a.rgb.b, b.rgb.b))
    }
}
