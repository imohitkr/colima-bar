import Testing

@testable import ColimaBar

@Suite struct VersionChangeTests {
    private func change(_ tool: VersionChange.Tool, _ kind: VersionChange.Kind) -> VersionChange {
        VersionChange(tool: tool, from: "1.0.0", to: "1.1.0", kind: kind)
    }

    @Test func aMinorMajorOrDowngradeOfColimaOrLimaIsRisky() {
        for tool in [VersionChange.Tool.colima, .lima] {
            #expect(change(tool, .minor).isRisky)
            #expect(change(tool, .major).isRisky)
            #expect(change(tool, .downgrade).isRisky)
            #expect(!change(tool, .patch).isRisky)
        }
    }

    @Test func aMacOSChangeIsNeverRisky() {
        for kind in [VersionChange.Kind.patch, .minor, .major, .downgrade] {
            #expect(!change(.macOS, kind).isRisky)
        }
    }

    @Test func kindIgnoresBuildSuffixesAndPadsShortVersions() {
        #expect(VersionChange.kind(from: "0.10.3", to: "0.10.3-4-gabc") == nil)
        #expect(VersionChange.kind(from: "2.2", to: "2.2.0") == nil)
        #expect(VersionChange.kind(from: "2.2", to: "2.3.1") == .minor)
        #expect(VersionChange.kind(from: "dev", to: "2.3.1") == nil)
    }

    @Test func textShowsToolAndBothVersions() {
        let c = VersionChange(tool: .colima, from: "0.10.3", to: "0.11.0", kind: .minor)
        #expect(c.text == "Colima 0.10.3 → 0.11.0")
    }
}
