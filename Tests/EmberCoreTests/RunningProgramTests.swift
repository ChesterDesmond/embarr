import Foundation
import Testing
@testable import EmberCore

/// The program tile lights up while it runs and goes dark as soon as anything changes the settings.
@Suite struct RunningProgramTests {
    let hot = Preset(name: "Hot sip", mode: .hold(45))

    @Test func chosenAndUnchangedIsRunning() {
        #expect(hot.isRunning(chosen: hot.id, current: .hold(45)))
    }

    @Test func movingTheSliderDeselects() {
        #expect(!hot.isRunning(chosen: hot.id, current: .hold(44.5)))
    }

    @Test func turningTheHeaterOffDeselects() {
        #expect(!hot.isRunning(chosen: hot.id, current: .off))
    }

    @Test func sameSettingsFromTheSliderAreNotThisProgram() {
        #expect(!hot.isRunning(chosen: nil, current: .hold(45)))
    }

    @Test func anotherProgramChosenIsNotThisOne() {
        #expect(!hot.isRunning(chosen: UUID(), current: .hold(45)))
    }
}
