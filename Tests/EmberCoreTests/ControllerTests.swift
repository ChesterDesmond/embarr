import Foundation
import Testing
@testable import EmberCore

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

@Suite struct CodecTests {
    @Test func tempRoundTrips() {
        #expect(EmberCodec.decodeTemp(Data([0x94, 0x11])) == 45.0)        // read off the mug
        #expect(EmberCodec.encodeTemp(45.0) == Data([0x94, 0x11]))
        #expect(EmberCodec.encodeTemp(0) == Data([0, 0]))
        #expect(EmberCodec.decodeTemp(Data([0x6b])) == nil)
    }

    @Test func decodesWhatTheMugReported() {
        #expect(EmberCodec.decodeBattery(Data([0x64, 0x00, 0xb0, 0x09])) == .init(percent: 100, charging: false))
        #expect(EmberCodec.decodeLiquidState(Data([0x06])) == .holding)
        #expect(EmberCodec.decodeLiquidState(Data([0x07])).hasLiquid)
        #expect(EmberCodec.decodeFirmware(Data([0x78, 0, 0x0c, 0, 0x71, 0])) == "firmware 120, hardware 12")
        #expect(EmberCodec.decodeLED(Data([0xff, 0x01, 0xf8, 0xff])) == .init(r: 255, g: 1, b: 248))
    }

    @Test func units() {
        #expect(TempUnit.fahrenheit.format(45) == "113°")
        #expect(abs(TempUnit.fahrenheit.toCelsius(98.6) - 37) < 0.001)
    }
}

@Suite struct ControllerTests {
    @Test func offModeWritesZero() {
        var c = HeaterController()
        let out = c.update(now: t0, temp: 70, state: .cooling, mode: .off)
        #expect(out.heaterTarget == 0)
        #expect(out.goal == nil)
    }

    @Test func nativeHoldAtOrAboveFloorGoesStraightToTheMug() {
        var c = HeaterController()
        #expect(c.update(now: t0, temp: 70, state: .cooling, mode: .hold(55)).heaterTarget == 55)
        #expect(c.update(now: t0, temp: 70, state: .cooling, mode: .hold(80)).heaterTarget == MugLimits.ceiling)
    }

    @Test func subFloorHoldLeavesHeaterOffWhileHotCoffeeCools() {
        var c = HeaterController()
        let out = c.update(now: t0, temp: 70, state: .cooling, mode: .hold(37))
        #expect(out.heaterTarget == 0)
        #expect(!out.pulsing)
    }

    @Test func subFloorHoldPulsesBelowTheBandAndCutsOffBeforeTheGoal() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(37))
        #expect(c.update(now: at(10), temp: 36.5, state: .cooling, mode: .hold(37)).heaterTarget == 0) // inside band
        let on = c.update(now: at(20), temp: 35.6, state: .cooling, mode: .hold(37))
        #expect(on.heaterTarget == MugLimits.floor)
        #expect(on.pulsing)
        // overshoot defaults to 1.0, so the heater cuts at 36.0
        #expect(c.update(now: at(30), temp: 35.9, state: .heating, mode: .hold(37)).heaterTarget == MugLimits.floor)
        #expect(c.update(now: at(40), temp: 36.0, state: .heating, mode: .hold(37)).heaterTarget == 0)
    }

    @Test func doesNotRepulseFasterThanTheMinimumInterval() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(37))
        _ = c.update(now: at(1), temp: 35, state: .cooling, mode: .hold(37))  // on
        _ = c.update(now: at(2), temp: 36.5, state: .heating, mode: .hold(37)) // off
        #expect(c.update(now: at(5), temp: 35, state: .cooling, mode: .hold(37)).heaterTarget == 0)
        #expect(c.update(now: at(25), temp: 35, state: .cooling, mode: .hold(37)).heaterTarget == MugLimits.floor)
    }

    @Test func learnsOvershootFromThePeakAfterCutoff() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(37))
        _ = c.update(now: at(1), temp: 35, state: .cooling, mode: .hold(37))   // on
        _ = c.update(now: at(2), temp: 36.0, state: .heating, mode: .hold(37)) // off at 36.0
        _ = c.update(now: at(60), temp: 39.0, state: .cooling, mode: .hold(37)) // peak +3.0
        _ = c.update(now: at(200), temp: 37.0, state: .cooling, mode: .hold(37)) // window over: learn
        #expect(abs(c.overshoot - (0.7 * 1.0 + 0.3 * 3.0)) < 0.0001)
    }

    @Test func largeOvershootWidensTheBandSoItNeverChatters() {
        var c = HeaterController()
        c.overshoot = 3
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(37))
        // cutoff is 34.0, so turn-on must be below it (37 - 3.3 = 33.7)
        #expect(c.update(now: at(1), temp: 33.9, state: .cooling, mode: .hold(37)).heaterTarget == 0)
        #expect(c.update(now: at(2), temp: 33.6, state: .cooling, mode: .hold(37)).heaterTarget == MugLimits.floor)
    }

    @Test func emptyMugTurnsPulsedHeaterOff() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(37))
        _ = c.update(now: at(1), temp: 35, state: .cooling, mode: .hold(37))
        let out = c.update(now: at(2), temp: 35, state: .empty, mode: .hold(37))
        #expect(out.heaterTarget == 0)
        #expect(out.events == [.emptied])
    }

    @Test func readyFiresOncePerFill() {
        var c = HeaterController()
        #expect(c.update(now: at(0), temp: 70, state: .filling, mode: .hold(55)).events == [.filled])
        #expect(c.update(now: at(1), temp: 55.4, state: .cooling, mode: .hold(55)).events == [.ready(target: 55)])
        #expect(c.update(now: at(2), temp: 55, state: .holding, mode: .hold(55)).events.isEmpty)
        _ = c.update(now: at(3), temp: 30, state: .empty, mode: .hold(55))
        #expect(c.update(now: at(4), temp: 70, state: .filling, mode: .hold(55)).events == [.filled])
    }

    @Test func glideStepsDownFromTheMomentOfFilling() {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 41, minutes: 10),
                               GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 70, state: .filling, mode: mode)
        #expect(c.goal(for: mode, now: at(5 * 60)) == 45)
        #expect(c.goal(for: mode, now: at(15 * 60)) == 41)
        #expect(c.goal(for: mode, now: at(90 * 60)) == 37)
        #expect(c.update(now: at(60), temp: 60, state: .cooling, mode: mode).heaterTarget == 45)
        #expect(c.update(now: at(15 * 60), temp: 44, state: .cooling, mode: mode).heaterTarget == 0)
    }

    @Test func unknownReadingLeavesTheMugAlone() {
        var c = HeaterController()
        #expect(c.update(now: t0, temp: nil, state: .cooling, mode: .hold(37)).heaterTarget == nil)
    }
}
