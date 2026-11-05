import Foundation
import Testing
@testable import EmberCore

@Suite struct NameTests {
    @Test func encodesPlainNames() {
        #expect(EmberCodec.encodeName("Chester's mug") == Data("Chester's mug".utf8))
        #expect(EmberCodec.encodeName("  Desk  ") == Data("Desk".utf8))   // trimmed
    }

    @Test func refusesWhatTheMugCannotStore() {
        #expect(EmberCodec.encodeName("") == nil)
        #expect(EmberCodec.encodeName("A name far too long") == nil)        // over 14
        #expect(EmberCodec.encodeName("Café") == nil)                       // not plain ASCII
        #expect(EmberCodec.encodeName("mug\u{0}") == nil)
    }

    @Test func decodesAndDropsPadding() {
        #expect(EmberCodec.decodeName(Data("Ember Cup\0\0".utf8)) == "Ember Cup")
        #expect(EmberCodec.decodeName(Data()) == nil)
    }

    @Test func hintListsTheSameCharactersTheCheckAllows() {
        for ch in EmberCodec.namePunctuation { #expect(EmberCodec.nameHint.contains(ch)) }
        #expect(EmberCodec.encodeName("A-b_c.d,'!&()") != nil)
    }

    @Test func programNamesAreTrimmed() {
        #expect(Preset.cleanName("  Morning  ") == "Morning")
        #expect(Preset.cleanName("   ") == nil)
    }

    @Test func recognizesEmberServices() {
        #expect(EmberUUID.isEmberService(EmberUUID.service))
        #expect(EmberUUID.isEmberService("fc543621-236c-4c94-8fa9-944a3e5353fa"))
        #expect(EmberUUID.isEmberService("FC5421A1-236C-4C94-8FA9-944A3E5353FA"))
        #expect(!EmberUUID.isEmberService("180F"))
    }

    @Test func colorOfNonsenseIsSafe() {
        #expect(TempColor.rgb(.nan) == TempColor.stops[0].rgb)
    }
}
