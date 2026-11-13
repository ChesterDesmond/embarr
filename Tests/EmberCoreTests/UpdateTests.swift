import Foundation
import Testing
@testable import EmberCore

@Suite struct UpdateTests {
    @Test func comparesVersionsPartByPart() {
        #expect(AppVersion("1.10")! > AppVersion("1.9")!)
        #expect(AppVersion("v1.8")! == AppVersion("1.8")!)
        #expect(AppVersion("1.8")! == AppVersion("1.8.0")!)
        #expect(AppVersion("1.8.1")! > AppVersion("1.8")!)
        #expect(AppVersion("2.0")! > AppVersion("1.99")!)
        #expect(AppVersion("1.8")!.description == "1.8")
    }

    @Test func refusesWhatIsNotAVersion() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("1.x") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("beta") == nil)
    }

    static let json = """
    {"tag_name":"v1.9","body":"New: a thing.","html_url":"https://github.com/ChesterDesmond/embarr/releases/tag/v1.9",
     "assets":[
      {"name":"Embarr-1.9.zip","browser_download_url":"https://github.com/ChesterDesmond/embarr/releases/download/v1.9/Embarr-1.9.zip"},
      {"name":"Embarr-1.9.zip.sha256","browser_download_url":"https://github.com/ChesterDesmond/embarr/releases/download/v1.9/Embarr-1.9.zip.sha256"}]}
    """

    @Test func readsGitHubsLatestRelease() throws {
        let r = try JSONDecoder().decode(Release.self, from: Data(Self.json.utf8))
        #expect(r.version == AppVersion("1.9"))
        #expect(r.notes == "New: a thing.")
        #expect(r.zip?.name == "Embarr-1.9.zip")
        #expect(r.checksum?.name == "Embarr-1.9.zip.sha256")
        #expect(r.isUpdate(over: AppVersion("1.8")!))
        #expect(!r.isUpdate(over: AppVersion("1.9")!))
        #expect(!r.isUpdate(over: AppVersion("2.0")!))
    }

    @Test func aReleaseWithoutItsChecksumIsNotOffered() {
        let page = URL(string: "https://example.com")!
        let r = Release(tag: "v2.0", notes: "", page: page, assets: [.init(name: "Embarr-2.0.zip", url: page)])
        #expect(r.zip != nil)
        #expect(r.checksum == nil)
        #expect(!r.isUpdate(over: AppVersion("1.8")!))
    }

    @Test func readsAChecksumFile() {
        let hex = String(repeating: "aB", count: 32)
        #expect(Checksum.parse("\(hex)  Embarr-1.9.zip\n") == hex.lowercased())
        #expect(Checksum.parse(hex) == hex.lowercased())
        #expect(Checksum.parse("nothexnothex  Embarr-1.9.zip") == nil)
        #expect(Checksum.parse("") == nil)
    }

    @Test func checksAtMostOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now))
        #expect(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))  // clock went backward
    }
}
