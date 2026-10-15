import Testing

@testable import ColimaBar

@Suite struct ToolVersionsTests {
    @Test func readsTheVersionOfEachTool() {
        #expect(ToolVersions.version(in: "colima version 0.10.3\ngit commit: abc123\n") == "0.10.3")
        #expect(ToolVersions.version(in: "limactl version 2.2.1\n") == "2.2.1")
        #expect(ToolVersions.version(in: "Docker version 29.0.1, build 1a2b3c4\n") == "29.0.1")
        #expect(ToolVersions.version(in: "limactl version v2.0.0-beta.1") == "2.0.0-beta.1")
    }

    @Test func returnsNilWhenNoWordIsAVersion() {
        #expect(ToolVersions.version(in: "") == nil)
        #expect(ToolVersions.version(in: "limactl version HEAD-abc") == nil)
        #expect(ToolVersions.version(in: "command not found: 29") == nil)
    }

    @Test func limaBefore21IsOld() {
        #expect(ToolVersions(lima: "2.0.3").limaIsOld)
        #expect(ToolVersions(lima: "1.2.1").limaIsOld)
        #expect(!ToolVersions(lima: "2.1.0").limaIsOld)
        #expect(!ToolVersions(lima: "2.2.1").limaIsOld)
        #expect(!ToolVersions(lima: nil).limaIsOld)
        #expect(!ToolVersions(lima: "dev").limaIsOld)
    }
}
