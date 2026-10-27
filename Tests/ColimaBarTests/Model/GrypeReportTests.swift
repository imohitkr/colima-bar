import Foundation
import Testing

@testable import ColimaBar

@Suite struct GrypeReportTests {
    private func findings(_ json: String) throws -> [ImageScanFinding] {
        try JSONDecoder().decode(GrypeReport.self, from: Data(json.utf8)).findings
    }

    @Test func readsTheFieldsOfAMatch() throws {
        let list = try findings(
            """
            {"matches":[{"vulnerability":{"id":"CVE-2024-0002","severity":"Critical",
              "description":"A flaw in zlib. It allows more.","fix":{"versions":["1.2.12","1.3"],"state":"fixed"}},
              "artifact":{"name":"zlib","version":"1.2.11","type":"deb"}}]}
            """)
        #expect(
            list == [
                ImageScanFinding(
                    vulnID: "CVE-2024-0002", package: "zlib", installed: "1.2.11", fixed: "1.2.12, 1.3",
                    severity: .critical, title: "A flaw in zlib")
            ])
    }

    @Test func negligibleIsLowAndAMissingFixIsNil() throws {
        let list = try findings(
            """
            {"matches":[{"vulnerability":{"id":"CVE-1","severity":"Negligible","fix":{"versions":[],"state":"not-fixed"}},
              "artifact":{"name":"a","version":"1"}}]}
            """)
        #expect(list.first?.severity == .low)
        #expect(list.first?.fixed == nil)
        #expect(list.first?.title == "")
    }

    @Test func noMatchesGivesNothing() throws {
        #expect(try findings(#"{"matches":[]}"#).isEmpty)
        #expect(try findings(#"{"descriptor":{"name":"grype"}}"#).isEmpty)
    }

    @Test func aLongTitleIsCut() {
        let title = GrypeReport.title(of: String(repeating: "word ", count: 60))
        #expect(title.count == GrypeReport.titleLimit)
        #expect(title.hasSuffix("…"))
        #expect(GrypeReport.title(of: "First line.\nSecond line.") == "First line")
    }

    @Test func badJSONDoesNotDecode() {
        #expect(throws: (any Error).self) { try findings("[1,2]") }
    }
}
