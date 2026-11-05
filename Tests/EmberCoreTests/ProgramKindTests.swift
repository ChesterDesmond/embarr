import Foundation
import Testing
@testable import EmberCore

@Suite struct ProgramKindTests {
    @Test func holdBecomesAGlideStartingThere() {
        let g = ProgramKind.glide.convert(.hold(41))
        #expect(g == .glide([GlideStep(target: 41, minutes: 10), GlideStep(target: 37, minutes: nil)]))
    }

    @Test func glideBecomesAHoldAtItsFirstStep() {
        #expect(ProgramKind.hold.convert(.glide([GlideStep(target: 45, minutes: 10)])) == .hold(45))
    }

    @Test func sameKindKeepsTheSettings() {
        let g = Mode.glide([GlideStep(target: 45, minutes: 5), GlideStep(target: 33, minutes: nil)])
        #expect(ProgramKind.glide.convert(g) == g)
        #expect(ProgramKind.hold.convert(.hold(38)) == .hold(38))
    }

    @Test func offAndBackGivesHotSip() {
        #expect(ProgramKind.off.convert(.hold(38)) == .off)
        #expect(ProgramKind.hold.convert(.off) == .hold(45))
        #expect(ProgramKind(.off) == .off)
    }

    @Test func glideNeverStepsBelowTheSliderBottom() {
        #expect(ProgramKind.glide.convert(.hold(31)) == .glide([GlideStep(target: 31, minutes: 10), GlideStep(target: 30, minutes: nil)]))
    }
}
