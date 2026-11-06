import Foundation
import Testing
@testable import EmberCore

@Suite struct ProgramTapTests {
    let hot = Preset(name: "Hot sip", mode: .hold(45))
    let warm = Preset(name: "Warm sip", mode: .hold(41))
    var presets: [Preset] { [hot, warm] }

    @Test func tapStartsTheProgramAndRemembersWhatItReplaced() {
        let slider = Running(mode: .hold(50), presetID: nil)
        let r = ProgramTap.tap(hot, now: slider, before: nil, presets: presets)
        #expect(r.next == Running(mode: .hold(45), presetID: hot.id))
        #expect(r.before == slider)
    }

    @Test func tappingTheRunningProgramGoesBack() {
        let slider = Running(mode: .hold(50), presetID: nil)
        let r = ProgramTap.tap(hot, now: Running(mode: .hold(45), presetID: hot.id), before: slider, presets: presets)
        #expect(r.next == slider)
        #expect(r.before == nil)
    }

    @Test func goingBackToAnotherProgramLightsIt() {
        let w = Running(mode: warm.mode, presetID: warm.id)
        let r = ProgramTap.tap(hot, now: Running(mode: hot.mode, presetID: hot.id), before: w, presets: presets)
        #expect(r.next == w)
    }

    @Test func nothingToGoBackToTurnsTheHeaterOff() {
        let r = ProgramTap.tap(hot, now: Running(mode: hot.mode, presetID: hot.id), before: nil, presets: presets)
        #expect(r.next == Running(mode: .off, presetID: nil))
    }

    @Test func aProgramEditedSinceComesBackAsPlainSettings() {
        let old = Running(mode: .hold(39), presetID: warm.id)  // Warm sip was 39 when it was replaced; it's 41 now
        let r = ProgramTap.tap(hot, now: Running(mode: hot.mode, presetID: hot.id), before: old, presets: presets)
        #expect(r.next == Running(mode: .hold(39), presetID: nil))
    }

    @Test func tappingAProgramAfterTheSliderMovedStartsItAgain() {
        let r = ProgramTap.tap(hot, now: Running(mode: .hold(44), presetID: nil), before: nil, presets: presets)
        #expect(r.next == Running(mode: hot.mode, presetID: hot.id))
    }
}

@Suite struct ProgramFileTests {
    func file(_ json: String) -> Data { Data(json.utf8) }

    @Test func roundTripsWithNewIDs() throws {
        let p = Preset(name: "Glide", mode: .glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 40, minutes: nil)]),
                       light: .init(r: 1, g: 2, b: 3))
        let all = [p, Preset(name: "Hot", mode: .hold(45)), Preset(name: "Cool", mode: .off)]
        let back = try ProgramFile.decode(ProgramFile.encode(all))
        #expect(back.map(\.name) == all.map(\.name))
        #expect(back.map(\.mode) == all.map(\.mode))
        #expect(back[0].light == p.light)
        #expect(back[0].id != p.id)
    }

    /// The file layout is a promise to everyone who has one saved: this exact text must keep importing.
    @Test func readsTheVersion1Layout() throws {
        let back = try ProgramFile.decode(file(#"""
        {"format":"Ember Bar programs","version":1,"programs":[
          {"name":"Hot sip","kind":"hold","celsius":45},
          {"name":"Glide","kind":"glide","steps":[{"celsius":45,"minutes":10},{"celsius":41}]},
          {"name":"Cool","kind":"off"}]}
        """#))
        #expect(back.map(\.mode) == [.hold(45), .glide([GlideStep(target: 45, minutes: 10), GlideStep(target: 41, minutes: nil)]), .off])
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: ProgramFile.Problem.notAProgramFile) { try ProgramFile.decode(file(#"{"a":1}"#)) }
    }

    @Test func rejectsANewerVersionAndEmptyFiles() {
        #expect(throws: ProgramFile.Problem.newerVersion) {
            try ProgramFile.decode(file(#"{"format":"Ember Bar programs","version":2,"programs":[{"some":"new shape"}]}"#))
        }
        #expect(throws: ProgramFile.Problem.noPrograms) {
            try ProgramFile.decode(file(#"{"format":"Ember Bar programs","version":1,"programs":[{"name":"x","kind":"glide","steps":[]}]}"#))
        }
    }

    @Test func skipsKindsItDoesNotKnow() throws {
        let back = try ProgramFile.decode(file(#"""
        {"format":"Ember Bar programs","version":1,"programs":[{"name":"a","kind":"warp"},{"name":"b","kind":"off"},{"kind":"hold"},{"name":"c","kind":"glide","steps":[{"minutes":3}]}]}
        """#))
        #expect(back.map(\.name) == ["b"])
    }

    @Test func keepsValuesInsideWhatTheEditorAllows() throws {
        let back = try ProgramFile.decode(file(#"""
        {"format":"Ember Bar programs","version":1,"programs":[
          {"name":"  ","kind":"hold","celsius":90},
          {"name":"g","kind":"glide","steps":[{"celsius":10},{"celsius":45,"minutes":500.4},{"celsius":40,"minutes":0.2}]}]}
        """#))
        #expect(back[0].mode == .hold(MugLimits.ceiling))
        #expect(back[0].name == "Imported program")
        #expect(back[1].mode == .glide([GlideStep(target: MugLimits.sliderFloor, minutes: 10),
                                        GlideStep(target: 45, minutes: 120), GlideStep(target: 40, minutes: 1)]))
    }

    @Test func mergeSkipsProgramsYouAlreadyHave() {
        let mine = [Preset(name: "Hot sip", mode: .hold(45))]
        let theirs = [Preset(name: "Hot sip", mode: .hold(45)), Preset(name: "Hot sip", mode: .hold(46)), Preset(name: "Cool", mode: .hold(35))]
        let r = ProgramFile.merge(theirs, into: mine)
        #expect(r.added == 2 && r.skipped == 1 && r.programs.count == 3)
    }
}
