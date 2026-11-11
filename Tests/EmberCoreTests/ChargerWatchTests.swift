import Foundation
import Testing
@testable import EmberCore

@Suite struct ChargerWatchTests {
    func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    @Test func asksOnceAfterAMinuteOffTheCharger() {
        var w = ChargerWatch()
        #expect(w.update(now: at(0), onCharger: false, hasLiquid: true, heaterOn: false) == nil)
        #expect(w.update(now: at(59), onCharger: false, hasLiquid: true, heaterOn: false) == nil)
        #expect(w.update(now: at(60), onCharger: false, hasLiquid: true, heaterOn: false) == .ask(heaterOn: false))
        #expect(w.update(now: at(200), onCharger: false, hasLiquid: true, heaterOn: false) == nil)
    }

    @Test func aSipDoesNotAsk() {
        var w = ChargerWatch()
        _ = w.update(now: at(0), onCharger: false, hasLiquid: true, heaterOn: true)
        #expect(w.update(now: at(20), onCharger: true, hasLiquid: true, heaterOn: true) == nil)
        #expect(w.update(now: at(70), onCharger: false, hasLiquid: true, heaterOn: true) == nil)  // clock restarted
        #expect(w.update(now: at(130), onCharger: false, hasLiquid: true, heaterOn: true) == .ask(heaterOn: true))
    }

    @Test func emptyMugWaitsForCoffee() {
        var w = ChargerWatch()
        #expect(w.update(now: at(0), onCharger: false, hasLiquid: false, heaterOn: false) == nil)
        #expect(w.update(now: at(300), onCharger: false, hasLiquid: false, heaterOn: false) == nil)
        #expect(w.update(now: at(310), onCharger: false, hasLiquid: true, heaterOn: false) == .ask(heaterOn: false))
    }

    @Test func backOnTheChargerWithdrawsAndRearms() {
        var w = ChargerWatch()
        _ = w.update(now: at(0), onCharger: false, hasLiquid: true, heaterOn: false)
        _ = w.update(now: at(60), onCharger: false, hasLiquid: true, heaterOn: false)
        #expect(w.update(now: at(90), onCharger: true, hasLiquid: true, heaterOn: false) == .withdraw)
        #expect(w.update(now: at(95), onCharger: true, hasLiquid: true, heaterOn: false) == nil)
        _ = w.update(now: at(100), onCharger: false, hasLiquid: true, heaterOn: true)
        #expect(w.update(now: at(160), onCharger: false, hasLiquid: true, heaterOn: true) == .ask(heaterOn: true))
    }

    @Test func unknownChargerChangesNothing() {
        var w = ChargerWatch()
        _ = w.update(now: at(0), onCharger: false, hasLiquid: true, heaterOn: false)
        #expect(w.update(now: at(30), onCharger: nil, hasLiquid: true, heaterOn: false) == nil)
        #expect(w.update(now: at(60), onCharger: false, hasLiquid: true, heaterOn: false) == .ask(heaterOn: false))
    }

    @Test func answeringBeforeTheMinuteStopsTheQuestion() {
        var w = ChargerWatch()
        _ = w.update(now: at(0), onCharger: false, hasLiquid: true, heaterOn: false)
        w.answered()
        #expect(w.update(now: at(60), onCharger: false, hasLiquid: true, heaterOn: false) == nil)
    }
}
