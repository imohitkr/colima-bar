import Foundation
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

    // MARK: changed(from:)

    private func change(_ old: ToolVersions, _ new: ToolVersions) -> [VersionChange.Kind] {
        new.changed(from: old).map(\.kind)
    }

    @Test func sortsAChangeAsPatchMinorMajorOrDowngrade() {
        let old = ToolVersions(colima: "0.10.3")
        #expect(change(old, ToolVersions(colima: "0.10.4")) == [.patch])
        #expect(change(old, ToolVersions(colima: "0.11.0")) == [.minor])
        #expect(change(old, ToolVersions(colima: "1.0.0")) == [.major])
        #expect(change(old, ToolVersions(colima: "0.10.2")) == [.downgrade])
        #expect(change(old, ToolVersions(colima: "0.9.9")) == [.downgrade])
    }

    @Test func reportsNoChangeForEqualMissingOrUnknownVersions() {
        let old = ToolVersions(colima: "0.10.3", lima: "2.2.1")
        #expect(ToolVersions(colima: "0.10.3", lima: "2.2.1").changed(from: old).isEmpty)
        #expect(ToolVersions(colima: "0.10.3-4-gabc-dirty", lima: "v2.2.1").changed(from: old).isEmpty)
        #expect(ToolVersions(colima: nil, lima: "unknown").changed(from: old).isEmpty)
        #expect(ToolVersions(colima: "0.11.0").changed(from: ToolVersions(colima: "unknown")).isEmpty)
        #expect(ToolVersions(colima: "0.10").changed(from: ToolVersions(colima: "0.10.0")).isEmpty)
    }

    @Test func listsTheToolsAndVersionsOfAChange() {
        let old = ToolVersions(colima: "0.10.3", lima: "2.2.1", macOS: "15.6")
        let now = ToolVersions(colima: "0.11.0", lima: "2.2.1", macOS: "15.6.1")
        let changes = now.changed(from: old)
        #expect(changes.map(\.tool) == [.colima, .macOS])
        #expect(changes[0].from == "0.10.3" && changes[0].to == "0.11.0")
    }

    @Test func ignoresDockerInAChange() {
        let old = ToolVersions(colima: "0.10.3", docker: "28.0.0")
        #expect(ToolVersions(colima: "0.10.3", docker: "29.0.1").changed(from: old).isEmpty)
    }

    @Test func recordLeavesOutDockerInItsJSON() throws {
        let v = ToolVersions(colima: "0.10.3", lima: "2.2.1", docker: "29.0.1", macOS: "15.6.1")
        let data = try JSONEncoder().encode(v)
        #expect(!String(decoding: data, as: UTF8.self).contains("docker"))
        let back = try JSONDecoder().decode(ToolVersions.self, from: data)
        #expect(back == ToolVersions(colima: "0.10.3", lima: "2.2.1", macOS: "15.6.1"))
    }

    @Test func writesTheMacOSVersionWithThreeNumbers() {
        #expect(
            ToolVersions.macOS(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)) == "15.6.1")
        #expect(
            ToolVersions.macOS(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == "26.0.0")
    }
}
