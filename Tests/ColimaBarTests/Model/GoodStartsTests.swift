import Testing

@testable import ColimaBar

@Suite struct GoodStartsTests {
    private let work = ToolVersions(colima: "0.10.3", lima: "2.2.1", macOS: "15.6.1")

    @Test func roundTripsThroughItsJSON() {
        let g = GoodStarts(records: ["work": work, "default": ToolVersions(colima: "0.9.1", lima: "1.2.0")])
        #expect(GoodStarts.decode(g.json) == g)
    }

    @Test func writesTheDocumentedShape() {
        let g = GoodStarts(records: ["work": work])
        #expect(g.json == #"{"work":{"colima":"0.10.3","lima":"2.2.1","macOS":"15.6.1"}}"#)
    }

    @Test func invalidOrMissingTextGivesNoRecords() {
        #expect(GoodStarts.decode(nil).records.isEmpty)
        #expect(GoodStarts.decode("").records.isEmpty)
        #expect(GoodStarts.decode("not json").records.isEmpty)
        #expect(GoodStarts.decode("[1,2]").records.isEmpty)
        #expect(GoodStarts.decode(#"{"work":"0.10.3"}"#).records.isEmpty)
    }

    @Test func pruneKeepsOnlyTheListedProfiles() {
        let g = GoodStarts(records: ["work": work, "old": work, "default": work])
        #expect(g.pruned(keeping: ["work", "default"]).records.keys.sorted() == ["default", "work"])
        #expect(g.pruned(keeping: ["work"]).records.keys.sorted() == ["work"])
    }

    @Test func pruneKeepsAProfileWithABusyMarker() {
        let g = GoodStarts(records: ["work": work, "old": work, "shrinking": work])
        #expect(g.pruned(keeping: ["work"], busy: ["shrinking"]).records.keys.sorted() == ["shrinking", "work"])
    }

    @Test func pruneWithNoListedProfileRemovesNothing() {
        let g = GoodStarts(records: ["work": work])
        #expect(g.pruned(keeping: [], busy: []) == g)
    }

    @Test func oneInvalidEntryDoesNotDropTheOthers() {
        let text = #"{"work":{"colima":"0.10.3","lima":"2.2.1"},"bad":{"colima":1},"worse":"x"}"#
        let (g, problem) = GoodStarts.decodeChecked(text)
        #expect(g.records.keys.sorted() == ["work"])
        #expect(problem == "2 invalid entries in the record of good starts")
    }

    @Test func aProblemTextNeverHasTheContent() {
        let (g, problem) = GoodStarts.decodeChecked("secret-not-json")
        #expect(g.records.isEmpty)
        #expect(problem?.contains("secret") == false)
        #expect(GoodStarts.decodeChecked(nil).problem == nil)
        #expect(GoodStarts.decodeChecked(g.json).problem == nil)
    }

    @Test func aSeedNeverReplacesARecord() {
        let old = ToolVersions(colima: "0.9.1", lima: "1.2.0")
        let g = GoodStarts(records: ["work": old])
        let seeded = g.seeded(["work", "other"], with: work)
        #expect(seeded.records["work"] == old)
        #expect(seeded.records["other"] == work)
    }
}
