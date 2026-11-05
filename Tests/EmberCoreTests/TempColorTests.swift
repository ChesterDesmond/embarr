import Foundation
import Testing
@testable import EmberCore

@Suite struct TempColorTests {
    @Test func stopsLandExactly() {
        for stop in TempColor.stops { #expect(TempColor.rgb(stop.celsius) == stop.rgb) }
    }

    @Test func clampsOutsideTheRange() {
        #expect(TempColor.rgb(10) == TempColor.stops.first!.rgb)
        #expect(TempColor.rgb(90) == TempColor.stops.last!.rgb)
    }

    @Test func coolIsBlueHotIsRed() {
        let cool = TempColor.rgb(32), hot = TempColor.rgb(61)
        #expect(cool.b > cool.r)
        #expect(hot.r > hot.b)
    }

    @Test func blendsBetweenStops() {
        let a = TempColor.stops[0], b = TempColor.stops[1]
        let mid = TempColor.rgb((a.celsius + b.celsius) / 2)
        #expect(Int(mid.g) == (Int(a.rgb.g) + Int(b.rgb.g) + 1) / 2 || Int(mid.g) == (Int(a.rgb.g) + Int(b.rgb.g)) / 2)
    }

    @Test func amberMarksWhereTheMugHoldsByItself() {
        #expect(TempColor.stops.contains { abs($0.celsius - MugLimits.lowestHeld) < 0.001 })
    }
}
