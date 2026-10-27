import Foundation
import Testing

@testable import ColimaBar

@Suite struct TrivyReportTests {
    private func findings(_ json: String) throws -> [ImageScanFinding] {
        try JSONDecoder().decode(TrivyReport.self, from: Data(json.utf8)).findings
    }

    @Test func readsTheFieldsOfAVulnerability() throws {
        let list = try findings(
            """
            {"SchemaVersion":2,"Results":[{"Target":"nginx (debian 12)","Class":"os-pkgs","Vulnerabilities":[
              {"VulnerabilityID":"CVE-2024-0001","PkgName":"libssl3","InstalledVersion":"3.0.1-1",
               "FixedVersion":"3.0.2-1","Severity":"HIGH","Title":" Buffer overflow ","Description":"long"}]}]}
            """)
        #expect(
            list == [
                ImageScanFinding(
                    vulnID: "CVE-2024-0001", package: "libssl3", installed: "3.0.1-1", fixed: "3.0.2-1",
                    severity: .high, title: "Buffer overflow")
            ])
    }

    @Test func aResultWithoutVulnerabilitiesGivesNothing() throws {
        #expect(try findings(#"{"Results":[{"Target":"x","Class":"os-pkgs"}]}"#).isEmpty)
        #expect(try findings(#"{"SchemaVersion":2}"#).isEmpty)
    }

    @Test func anEmptyFixedVersionMeansNoFix() throws {
        let list = try findings(
            #"{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-1","PkgName":"a","FixedVersion":"","Severity":"LOW"}]}]}"#
        )
        #expect(list.first?.fixed == nil)
        #expect(list.first?.isFixable == false)
    }

    @Test(arguments: [
        ("CRITICAL", ImageScanSeverity.critical), ("MEDIUM", .medium), ("UNKNOWN", .unknown), ("odd", .unknown),
    ])
    func mapsTheSeverityWords(word: String, level: ImageScanSeverity) throws {
        let list = try findings(
            #"{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-1","PkgName":"a","Severity":"\#(word)"}]}]}"#)
        #expect(list.first?.severity == level)
    }

    @Test func badJSONDoesNotDecode() {
        #expect(throws: (any Error).self) { try findings("not json") }
        #expect(throws: (any Error).self) { try findings(#"{"Results":[{"Vulnerabilities":[{"PkgName":"a"}]}]}"#) }
    }
}
