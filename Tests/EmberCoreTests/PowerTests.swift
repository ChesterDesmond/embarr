import Foundation
import Testing
@testable import EmberCore

@Suite struct PowerTests {
    let glide = Mode.glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 37, minutes: nil)])
    let id = UUID()

    @Test func onReturnsToTheLastProgram() {
        var p = PowerMemory()
        p.chose(glide, presetID: id)
        p.chose(.off, presetID: nil)            // "Just let it cool" doesn't overwrite what On goes back to
        let on = p.turnOn()
        #expect(on.mode == glide)
        #expect(on.presetID == id)
    }

    @Test func onWithNothingRememberedUsesHotSip() {
        var p = PowerMemory()
        #expect(p.turnOn().mode == .hold(45))
    }

    @Test func pauseResumesOnTimeAndOnlyOnce() {
        var p = PowerMemory()
        p.chose(.hold(41), presetID: nil)
        p.pause(until: at(900))
        #expect(p.isPaused(now: at(10)))
        #expect(p.dueResume(now: at(899)) == nil)
        let back = p.dueResume(now: at(900))
        #expect(back?.mode == .hold(41))
        #expect(!p.isPaused(now: at(901)))
        #expect(p.dueResume(now: at(1000)) == nil)
    }

    @Test func aPauseThatRanOutLongAgoStaysOff() {
        var p = PowerMemory()
        p.chose(.hold(41), presetID: nil)
        p.pause(until: at(900))                     // then the app was quit overnight
        #expect(p.dueResume(now: at(900 + PowerMemory.lateResumeLimit + 1)) == nil)
        #expect(p.pausedUntil == nil)
        #expect(p.turnOn().mode == .hold(41))       // On still knows what to go back to
    }

    @Test func choosingSomethingCancelsThePause() {
        var p = PowerMemory()
        p.chose(.hold(41), presetID: nil)
        p.pause(until: at(900))
        p.chose(.hold(37), presetID: nil)
        #expect(!p.isPaused(now: at(10)))
        #expect(p.dueResume(now: at(2000)) == nil)
        #expect(p.turnOn().mode == .hold(37))
    }

    @Test func stayOffEndsThePauseButRemembersTheProgram() {
        var p = PowerMemory()
        p.chose(.hold(41), presetID: nil)
        p.pause(until: at(900))
        p.endPause()
        #expect(p.dueResume(now: at(1000)) == nil)
        #expect(p.turnOn().mode == .hold(41))
    }

    @Test func turningOnEndsThePause() {
        var p = PowerMemory()
        p.chose(.hold(41), presetID: nil)
        p.pause(until: at(900))
        _ = p.turnOn()
        #expect(p.dueResume(now: at(2000)) == nil)
    }

    @Test func survivesARelaunch() throws {
        var p = PowerMemory()
        p.chose(glide, presetID: id)
        p.pause(until: at(900))
        let back = try JSONDecoder().decode(PowerMemory.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(try JSONDecoder().decode(PowerMemory.self, from: Data("{}".utf8)) == PowerMemory())
    }

    @Test func resumingKeepsTheGlideClock() {
        var c = HeaterController()
        _ = c.update(now: at(0), temp: 60, state: .filling, mode: glide)
        _ = c.update(now: at(30), temp: 60, state: .cooling, mode: glide)
        let poured = c.fillStart
        c.resetForNewMode(now: at(400), keepCupClock: true)
        #expect(c.fillStart == poured)
        c.resetForNewMode(now: at(500))
        #expect(c.fillStart == at(500))
    }

    @Test func resumeUsesTheProgramAsEditedNotAsRemembered() {
        let edited = Preset(id: id, name: "Specialty glide", mode: .hold(50))
        let back = PowerMemory.current((glide, id), in: [edited])
        #expect(back.mode == .hold(50))
        #expect(back.presetID == id)
    }

    @Test func resumeOfADeletedProgramKeepsItsLastSettings() {
        let back = PowerMemory.current((glide, id), in: [])
        #expect(back.mode == glide)
        #expect(back.presetID == nil)
    }
}
