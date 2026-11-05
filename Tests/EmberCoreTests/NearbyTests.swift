import Foundation
import Testing
@testable import EmberCore

@Suite struct NearbyTests {
    let a = UUID(), b = UUID()

    @Test func onlyEmbersAreListed() {
        var n = NearbyMugs()
        n.saw(id: a, name: "Ember Cup", rssi: -60, at: at(0))
        n.saw(id: b, name: "AirPods", rssi: -40, at: at(0))
        #expect(n.list(now: at(1)).map(\.id) == [a])
    }

    @Test func rowsKeepTheirOrderAndUpdateInPlace() {
        var n = NearbyMugs()
        n.saw(id: a, name: "Ember Cup", rssi: -80, at: at(0))
        n.saw(id: b, name: "Ember Mug 2", rssi: -50, at: at(1))
        #expect(n.list(now: at(1)).map(\.id) == [a, b])
        n.saw(id: a, name: "Kitchen", rssi: -40, at: at(2))     // stronger now: still first, not reshuffled
        n.saw(id: b, name: "Ember Mug 2", rssi: -90, at: at(2))
        let list = n.list(now: at(3))
        #expect(list.map(\.id) == [a, b])
        #expect(list.first?.name == "Kitchen")
        #expect(list.count == 2)
    }

    @Test func mugsThatGoQuietDropOff() {
        var n = NearbyMugs()
        n.saw(id: a, name: "Ember Cup", rssi: -60, at: at(0))
        n.saw(id: b, name: "Ember Cup", rssi: -60, at: at(50))
        #expect(n.list(now: at(60)).map(\.id) == [b])
    }

    @Test func aRenamedMugStillCountsOnceKnownAsAnEmber() {
        var n = NearbyMugs()
        n.saw(id: a, name: "Ember Cup", rssi: -60, at: at(0))
        n.saw(id: a, name: "Kitchen", rssi: -60, at: at(5))     // renamed: no "Ember" prefix any more
        #expect(n.list(now: at(6)).first?.name == "Kitchen")
        #expect(NearbyMugs.looksLikeEmber(name: "Kitchen", advertisesEmberService: true))
    }
}
