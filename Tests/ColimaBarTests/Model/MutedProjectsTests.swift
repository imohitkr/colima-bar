import Testing

@testable import ColimaBar

@Suite struct MutedProjectsTests {
    @Test func decodeDropsJunk() {
        let long = "p/" + String(repeating: "a", count: 200)
        let raw = ["default/web", "nosep", "/web", "default/", "", long, "work/api"]
        #expect(MutedProjects.decode(raw) == ["default/web", "work/api"])
        #expect(MutedProjects.decode(nil).isEmpty)
    }

    @Test func decodeCapsTheList() {
        let raw = (0..<300).map { "p/n\($0)" }
        #expect(MutedProjects.decode(raw).count == MutedProjects.maxCount)
    }

    @Test func encodeIsSorted() {
        #expect(MutedProjects.encode(["work/b", "default/z", "default/a"]) == ["default/a", "default/z", "work/b"])
    }

    @Test func toggleAddsAndRemoves() {
        var s = MutedProjects.toggled([], key: "default/web", muted: true)
        #expect(s == ["default/web"])
        s = MutedProjects.toggled(s, key: "default/web", muted: true)
        #expect(s == ["default/web"])
        s = MutedProjects.toggled(s, key: "default/web", muted: false)
        #expect(s.isEmpty)
    }

    @Test func toggleRefusesAnAddAtTheCapButNotARemoval() {
        let full = Set((0..<MutedProjects.maxCount).map { "p/n\($0)" })
        #expect(MutedProjects.toggled(full, key: "p/new", muted: true) == full)
        #expect(MutedProjects.toggled(full, key: "p/n1", muted: false).count == MutedProjects.maxCount - 1)
    }

    @Test func toggleRefusesAnInvalidKey() {
        #expect(MutedProjects.toggled([], key: "web", muted: true).isEmpty)
    }

    @Test func keyFormatIsTheComposeKey() {
        let key = ColimaModel.composeKey(profile: "default", name: "web")
        #expect(MutedProjects.toggled([], key: key, muted: true) == [key])
        #expect(MutedProjects.decode([key]) == [key])
    }
}
