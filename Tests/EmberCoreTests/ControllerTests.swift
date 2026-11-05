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
        #expect(TempUnit.fahrenheit.dual(45) == "113°F / 45°C")
        #expect(TempUnit.celsius.dual(37) == "37°C / 99°F")
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
        #expect(on.heaterTarget == MugLimits.pulseOn)
        #expect(on.pulsing)
        // overshoot defaults to 1.0, so the heater cuts at 36.0
        #expect(c.update(now: at(24), temp: 35.9, state: .heating, mode: .hold(37)).heaterTarget == MugLimits.pulseOn)
        #expect(c.update(now: at(25), temp: 36.0, state: .heating, mode: .hold(37)).heaterTarget == 0)
    }

    @Test func aBurstNeverRunsLongerThanTheCapEvenIfTheSensorLags() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(37))
        #expect(c.update(now: at(1), temp: 35, state: .cooling, mode: .hold(37)).pulsing)
        #expect(c.update(now: at(8), temp: 35.1, state: .heating, mode: .hold(37)).pulsing)
        #expect(c.update(now: at(9), temp: 35.1, state: .heating, mode: .hold(37)).heaterTarget == 0)
    }

    @Test func waitsForTheLastBurstToPeakBeforeTheNext() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(37))
        _ = c.update(now: at(1), temp: 35, state: .cooling, mode: .hold(37))  // on
        _ = c.update(now: at(2), temp: 36.5, state: .heating, mode: .hold(37)) // off
        #expect(c.update(now: at(5), temp: 35, state: .cooling, mode: .hold(37)).heaterTarget == 0)
        // risen to 37 and not yet turned down: still watching
        #expect(c.update(now: at(100), temp: 37, state: .cooling, mode: .hold(37)).heaterTarget == 0)
        #expect(c.update(now: at(130), temp: 35, state: .cooling, mode: .hold(37)).heaterTarget == MugLimits.pulseOn)
    }

    @Test func theNextBurstMayStartAsSoonAsTheLastOneHasPeaked() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 40, state: .cooling, mode: .hold(41))
        _ = c.update(now: at(1), temp: 38, state: .cooling, mode: .hold(41))   // on
        _ = c.update(now: at(9), temp: 38, state: .heating, mode: .hold(41))   // cap: off at 38
        _ = c.update(now: at(40), temp: 39.5, state: .cooling, mode: .hold(41)) // rising
        // turned down 0.4 from the 39.5 peak: learn a 1.5 rise, and the window closes early (50 s, not 120)
        let next = c.update(now: at(50), temp: 39.1, state: .cooling, mode: .hold(41))
        #expect(abs(c.overshoot - (0.7 + 0.3 * 1.5)) < 0.0001)
        // turn-on is now 41 - max(0.8, 1.15 + 0.3) = 39.55; 39.1 is below it and the 20 s spacing has passed
        #expect(next.heaterTarget == MugLimits.pulseOn)
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
        #expect(c.update(now: at(2), temp: 33.6, state: .cooling, mode: .hold(37)).heaterTarget == MugLimits.pulseOn)
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
        _ = c.update(now: at(61), temp: 60, state: .cooling, mode: .hold(55))
        #expect(c.update(now: at(90), temp: 55.4, state: .cooling, mode: .hold(55)).events == [.ready(target: 55)])
        #expect(c.update(now: at(92), temp: 55, state: .holding, mode: .hold(55)).events.isEmpty)
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
        // 45 is below what the mug holds by itself, so the first leg is pulsed too: hot coffee just cools
        #expect(c.update(now: at(60), temp: 60, state: .cooling, mode: mode).heaterTarget == 0)
        #expect(c.update(now: at(15 * 60), temp: 44, state: .cooling, mode: mode).heaterTarget == 0)
    }

    @Test func unknownReadingLeavesTheMugAlone() {
        var c = HeaterController()
        #expect(c.update(now: t0, temp: nil, state: .cooling, mode: .hold(37)).heaterTarget == nil)
    }

    // Measured 2026-11-05: with target 45.00 the mug reported "Holding" at 48.89 (120 F) for two hours.
    @Test func goalsBelowWhatTheMugHoldsArePulsedNotHandedToTheMug() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 50, state: .cooling, mode: .hold(45))
        #expect(c.update(now: at(1), temp: 48.89, state: .holding, mode: .hold(45)).heaterTarget == 0)
        let on = c.update(now: at(2), temp: 43.5, state: .cooling, mode: .hold(45))
        #expect(on.heaterTarget == MugLimits.pulseOn)
        #expect(on.pulsing)
        #expect(c.update(now: at(0), temp: 50, state: .cooling, mode: .hold(48.9)).heaterTarget == 48.9)
    }

    // Seen 2026-11-05 10:42:48: "Coffee is ready" fired the instant coffee was poured, because the
    // sensor still read 32.78 while the mug said Filling.
    @Test func readyWaitsForTheCoffeeToComeDownNotForAColdSensorAtPour() {
        var c = HeaterController()
        #expect(c.update(now: at(0), temp: 32.78, state: .filling, mode: .hold(45)).events == [.filled])
        #expect(c.update(now: at(20), temp: 43.9, state: .heating, mode: .hold(45)).events.isEmpty)
        #expect(c.update(now: at(40), temp: 60, state: .cooling, mode: .hold(45)).events.isEmpty)
        #expect(c.update(now: at(400), temp: 45.4, state: .cooling, mode: .hold(45)).events == [.ready(target: 45)])
    }

    @Test func switchingToAGoalAboveTheCoffeeDoesNotAnnounceReady() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: .hold(55))
        _ = c.update(now: at(100), temp: 50, state: .cooling, mode: .hold(55))
        c.resetForNewMode(now: at(101))
        #expect(c.update(now: at(102), temp: 50, state: .cooling, mode: .hold(52)).events.isEmpty)
    }
}

extension ControllerTests {
    @Test func coffeePouredCoolerThanTheGoalIsReadyOnceTheMugWarmsItUp() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 52, state: .filling, mode: .hold(55))
        #expect(c.update(now: at(70), temp: 53, state: .heating, mode: .hold(55)).events.isEmpty)
        #expect(c.update(now: at(200), temp: 54.6, state: .heating, mode: .hold(55)).events == [.ready(target: 55)])
    }

    @Test func savedTuningSurvivesKeysThisBuildDoesNotKnow() throws {
        let saved = #"{"overshoot":2.5,"band":1.2,"tuning":2,"pulsing":false,"someFutureKey":1}"#
        let c = try JSONDecoder().decode(HeaterController.self, from: Data(saved.utf8))
        #expect(c.overshoot == 2.5)
        #expect(c.band == 1.2)
        #expect(c.learnWindow == 120)
    }

    @Test func aRelaunchMidCupKeepsTheGlideWhereItWas() throws {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        var back = try JSONDecoder().decode(HeaterController.self, from: JSONEncoder().encode(c))
        #expect(back.goal(for: mode, now: at(14 * 60)) == 37)
        #expect(back.update(now: at(14 * 60), temp: 36, state: .cooling, mode: mode).events.isEmpty) // no re-"filled"
    }

    @Test func aRelaunchAfterALongAbsenceIsANewCup() throws {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        _ = c.update(now: at(40 * 60), temp: 37, state: .cooling, mode: mode)
        var back = try JSONDecoder().decode(HeaterController.self, from: JSONEncoder().encode(c))
        #expect(back.update(now: at(3 * 3600), temp: 60, state: .cooling, mode: mode).events == [.filled])
        #expect(back.goal(for: mode, now: at(3 * 3600 + 60)) == 45)
    }

    @Test func aSaveFromBeforeLastSeenKeepsTheCup() throws {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        let saved = #"{"band":0.8,"overshoot":1,"fillStart":0,"hadLiquid":true}"#
        var c = try JSONDecoder().decode(HeaterController.self, from: Data(saved.utf8))
        #expect(c.update(now: Date(timeIntervalSinceReferenceDate: 3 * 3600), temp: 37, state: .cooling, mode: mode).events.isEmpty)
    }

    @Test func aCupThatOnlyCooledWhileTheLidWasClosedIsTheSameCup() throws {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        _ = c.update(now: at(20 * 60), temp: 38, state: .cooling, mode: mode)
        c.lostContact()
        #expect(c.update(now: at(80 * 60), temp: 25, state: .cooling, mode: mode).events.isEmpty)
        #expect(c.goal(for: mode, now: at(80 * 60)) == 37)
    }

    @Test func aQuickRelaunchOnAnOldCupKeepsItsGlide() throws {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        _ = c.update(now: at(3 * 3600), temp: 37, state: .cooling, mode: mode)
        var back = try JSONDecoder().decode(HeaterController.self, from: JSONEncoder().encode(c))
        #expect(back.update(now: at(3 * 3600 + 30), temp: 37, state: .cooling, mode: mode).events.isEmpty)
        #expect(back.goal(for: mode, now: at(3 * 3600 + 30)) == 37)
    }

    @Test func aCupRefilledOutOfRangeIsANewCup() {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        _ = c.update(now: at(40 * 60), temp: 37, state: .cooling, mode: mode)
        c.lostContact()
        _ = c.update(now: at(3 * 3600), temp: nil, state: .unknown, mode: mode) // first read not in yet
        #expect(c.update(now: at(3 * 3600 + 3), temp: 60, state: .cooling, mode: mode).events == [.filled])
    }

    @Test func aRefillCaughtMidPourAfterAGapStillCountsOnceThePourIsDone() {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        _ = c.update(now: at(40 * 60), temp: 37, state: .cooling, mode: mode)
        c.lostContact()
        #expect(c.update(now: at(3 * 3600), temp: 32.78, state: .filling, mode: mode).events.isEmpty)
        #expect(c.update(now: at(3 * 3600 + 20), temp: 58, state: .heating, mode: mode).events == [.filled])
    }

    @Test func aBurstThatKeptHeatingAfterTheLinkDroppedIsNotARefill() {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        _ = c.update(now: at(40 * 60), temp: 36, state: .cooling, mode: mode)
        c.lostContact()
        #expect(c.update(now: at(60 * 60), temp: 48.9, state: .holding, mode: mode).events.isEmpty)
    }

    @Test func coldCoffeeFoundAfterAGapIsNotReady() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: .hold(41))
        _ = c.update(now: at(90), temp: 55, state: .cooling, mode: .hold(41))
        #expect(c.update(now: at(3600), temp: 30, state: .cooling, mode: .hold(41)).events.isEmpty)
    }

    @Test func aPourIntoAnEmptyMugAfterAGapFiresFilledOnce() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 30, state: .empty, mode: .hold(41))
        c.lostContact()
        #expect(c.update(now: at(3600), temp: 32.78, state: .filling, mode: .hold(41)).events == [.filled])
        #expect(c.update(now: at(3620), temp: 58, state: .heating, mode: .hold(41)).events.isEmpty)
    }

    @Test func aBurstOnWhenTheLinkDroppedIsForgottenNotLearnedFrom() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 45, state: .cooling, mode: .hold(41))
        #expect(c.update(now: at(100), temp: 39, state: .cooling, mode: .hold(41)).pulsing)
        c.lostContact()
        #expect(!c.update(now: at(1300), temp: 48.9, state: .holding, mode: .hold(41)).pulsing)
        _ = c.update(now: at(1340), temp: 48.0, state: .cooling, mode: .hold(41))
        #expect(c.overshoot == 1.0)
    }

    @Test func aBlipMidBurstStillWaitsForThatBurstsPeak() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 45, state: .cooling, mode: .hold(41))
        #expect(c.update(now: at(100), temp: 39.3, state: .cooling, mode: .hold(41)).pulsing)
        c.lostContact()
        // back 18 s later, sensor still lagging low: no second burst yet
        #expect(c.update(now: at(118), temp: 39.4, state: .heating, mode: .hold(41)).heaterTarget == 0)
        #expect(c.update(now: at(121), temp: 39.4, state: .cooling, mode: .hold(41)).heaterTarget == 0)
        _ = c.update(now: at(170), temp: 42.0, state: .cooling, mode: .hold(41))   // the spike arrives
        _ = c.update(now: at(200), temp: 41.5, state: .cooling, mode: .hold(41))   // turned down: done, not learned
        #expect(c.overshoot == 1.0)
    }

    @Test func aCupKeptInTheMugForHoursIsStillTheSameCup() {
        let mode = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: mode)
        #expect(c.update(now: at(3 * 3600), temp: 36, state: .cooling, mode: mode).events.isEmpty)
        #expect(c.goal(for: mode, now: at(3 * 3600)) == 37)
    }

    @Test func noiseRightAfterACutoffDoesNotEndTheWait() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 41, state: .cooling, mode: .hold(41))
        _ = c.update(now: at(1), temp: 39.45, state: .cooling, mode: .hold(41)) // on
        _ = c.update(now: at(9), temp: 39.45, state: .heating, mode: .hold(41)) // cap: off
        _ = c.update(now: at(12), temp: 39.47, state: .cooling, mode: .hold(41)) // +0.02 noise
        #expect(c.update(now: at(20), temp: 39.10, state: .cooling, mode: .hold(41)).heaterTarget == 0) // too soon
        #expect(c.update(now: at(40), temp: 39.30, state: .cooling, mode: .hold(41)).heaterTarget == 0) // within noise
        #expect(c.overshoot == 1.0) // nothing learned yet
    }

    @Test func aBurstThatNeverLiftsTheReadingDoesNotHoldUpTheNext() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 41, state: .cooling, mode: .hold(41))
        _ = c.update(now: at(1), temp: 39.45, state: .cooling, mode: .hold(41)) // on
        _ = c.update(now: at(9), temp: 39.45, state: .heating, mode: .hold(41)) // cap: off
        let next = c.update(now: at(45), temp: 39.1, state: .cooling, mode: .hold(41))
        #expect(next.heaterTarget == MugLimits.pulseOn)
        #expect(abs(c.overshoot - 0.7) < 0.0001) // learned a rise of 0
    }

    @Test func aStaleCutoffLearnsOnlyFromItsOwnWindow() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 41, state: .cooling, mode: .hold(41))
        _ = c.update(now: at(1), temp: 39, state: .cooling, mode: .hold(41))  // on
        _ = c.update(now: at(9), temp: 39, state: .heating, mode: .hold(41))  // off at 39
        _ = c.update(now: at(60), temp: 39.6, state: .cooling, mode: .hold(41)) // peak +0.6 within the window
        _ = c.update(now: at(600), temp: 55, state: .cooling, mode: .hold(41)) // much later and hot
        #expect(abs(c.overshoot - (0.7 + 0.3 * 0.6)) < 0.0001)
    }

    @Test func oneTwentyFahrenheitIsHeldByTheMug() {
        let f120 = TempUnit.fahrenheit.toCelsius(120)
        #expect(!MugLimits.needsPulsing(f120))
        #expect(MugLimits.needsPulsing(TempUnit.fahrenheit.toCelsius(119)))
        var c = HeaterController()
        #expect(c.update(now: t0, temp: 60, state: .cooling, mode: .hold(f120)).heaterTarget == f120)
    }

    // The first build's save: overshoot 4 learned from uncapped 30 s bursts. Keep the band, relearn the overshoot.
    @Test func overshootLearnedFromUncappedBurstsIsDropped() throws {
        let firstBuild = #"{"overshoot":4,"announcedReady":true,"hadLiquid":true,"learnWindow":120,"band":1.1,"pulsing":false,"minOnInterval":20}"#
        let c = try JSONDecoder().decode(HeaterController.self, from: Data(firstBuild.utf8))
        #expect(c.overshoot == 1.0)
        #expect(c.band == 1.1)
    }
}

@Suite struct AverageTests {
    @Test func nativeHoldAveragesItsTarget() {
        #expect(HeaterController().approxAverage(.hold(55)) == 55)
        #expect(HeaterController().approxAverage(.off) == nil)
    }

    @Test func pulsedHoldAveragesTheMiddleOfItsSwing() {
        // turn-on at 37 - max(0.8, 1.0 + 0.3) = 35.7, top of the swing about 37
        let c = HeaterController()
        #expect(abs(c.approxAverage(.hold(37))! - 36.35) < 0.001)
        #expect(c.swing(around: 37).low == 35.7)
    }

    @Test func glideWeighsEachStepByItsMinutesOverAThirtyMinuteCup() {
        var c = HeaterController()
        c.band = 2; c.overshoot = 0.2 // swing of 2, so each step averages target - 1
        let g = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 41, minutes: 10),
                            GlideStep(target: 37, minutes: nil)])
        #expect(abs(c.approxAverage(g)! - (44 + 40 + 36) / 3) < 0.001)
        let short = Mode.glide([GlideStep(target: 45, minutes: 40), GlideStep(target: 37, minutes: nil)])
        #expect(abs(c.approxAverage(short)! - 44) < 0.001)
    }
}

@Suite struct StatusTests {
    func phase(_ state: LiquidState = .cooling, temp: Double? = 40, goal: Double? = 37, pulsing: Bool = false,
               connected: Bool = true) -> HeaterPhase {
        HeaterPhase(connected: connected, state: state, temp: temp, goal: goal, pulsing: pulsing)
    }

    @Test func phases() {
        #expect(phase(connected: false) == .unavailable)
        #expect(phase(.empty) == .unavailable)
        #expect(phase(pulsing: true) == .heating)
        #expect(phase(.heating, temp: 50, goal: 55) == .heating)
        #expect(phase(goal: nil) == .heaterOff)
        #expect(phase(temp: 40, goal: 37) == .coolingToGoal)
        #expect(phase(temp: 36.8, goal: 37) == .resting)       // between pulses
        #expect(phase(.holding, temp: 55, goal: 55) == .holding) // the mug holds it itself
    }

    @Test func cyclingModes() {
        #expect(Mode.hold(37).isCycling)
        #expect(Mode.hold(45).isCycling)
        #expect(!Mode.hold(55).isCycling)
        #expect(Mode.glide([GlideStep(target: 41, minutes: nil)]).isCycling)
        #expect(!Mode.glide([GlideStep(target: 55, minutes: 5), GlideStep(target: 50, minutes: nil)]).isCycling)
        #expect(!Mode.off.isCycling)
    }
}

@Suite struct LightTests {
    let teal = EmberCodec.RGB(r: 0, g: 200, b: 180)

    @Test func steadyUnlessCycling() {
        #expect(MugLight.color(base: teal, blinking: false, tick: 1) == teal)
        #expect(MugLight.color(base: teal, blinking: true, tick: 0) == teal)
        #expect(MugLight.color(base: teal, blinking: true, tick: 1) == teal.dimmed(MugLight.dimFraction))
        #expect(MugLight.color(base: teal, blinking: true, tick: 2) == teal)
    }

    @Test func dimKeepsTheHue() {
        #expect(EmberCodec.RGB(r: 200, g: 100, b: 0).dimmed(0.5) == .init(r: 100, g: 50, b: 0))
    }
}
