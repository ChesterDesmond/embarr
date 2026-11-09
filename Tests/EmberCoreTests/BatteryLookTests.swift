import Testing
@testable import EmberCore

@Suite struct BatteryLookTests {
    private func b(_ percent: Int, charging: Bool = false) -> EmberCodec.Battery { .init(percent: percent, charging: charging) }

    @Test func tierFollowsCharge() {
        #expect(b(100).tier == .good)
        #expect(b(50).tier == .good)
        #expect(b(49).tier == .fair)
        #expect(b(21).tier == .fair)
        #expect(b(20).tier == .low)
        #expect(b(0).tier == .low)
    }

    @Test func chargingIsAlwaysGood() {
        #expect(b(5, charging: true).tier == .good)
    }

    @Test func symbolFillsWithCharge() {
        #expect(b(100).symbolName == "battery.100percent")
        #expect(b(80).symbolName == "battery.75percent")
        #expect(b(50).symbolName == "battery.50percent")
        #expect(b(20).symbolName == "battery.25percent")
        #expect(b(5).symbolName == "battery.0percent")
        #expect(b(40, charging: true).symbolName == "battery.100percent.bolt")
    }

    @Test func outOfRangeReadingsAreClamped() {
        #expect(b(130).symbolName == "battery.100percent")
        #expect(b(-3).tier == .low)
    }
}
