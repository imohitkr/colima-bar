import Foundation
import Testing

@testable import ColimaBar

@Suite struct DoctorReportTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func report(_ results: [DoctorResult]) -> DoctorReport {
        DoctorReport(profile: "work", date: date, results: results)
    }

    @Test func theSummaryCountsProblemsAndWarnings() {
        #expect(report([]).summary == "No problems")
        #expect(report([.init(.tools, .ok, "x")]).summary == "No problems")
        #expect(report([.init(.tools, .problem, "x")]).summary == "1 problem")
        let mixed = report([
            .init(.tools, .problem, "x"), .init(.context, .warning, "y"), .init(.plugins, .warning, "z"),
            .init(.diskSpace, .skipped, "s"),
        ])
        #expect(mixed.summary == "1 problem, 2 warnings")
        #expect(mixed.problems == 1 && mixed.warnings == 2)
    }

    @Test func aReportIsStaleAfterFiveMinutes() {
        let r = report([])
        #expect(!r.isStale(now: date.addingTimeInterval(299)))
        #expect(r.isStale(now: date.addingTimeInterval(301)))
    }

    @Test func theTextShowsTheHomeFolderAsTildeAndHasOneLinePerCheck() {
        let r = report([
            .init(.shellHost, .warning, "/Users/me/.zshrc line 3 sets DOCKER_HOST"),
            .init(.tools, .ok, "colima 0.10.3"),
        ])
        let lines = r.text(home: "/Users/me", version: "0.8.0").split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "ColimaBar 0.8.0, profile work, 1 warning")
        #expect(lines[1] == "[warning] Shell DOCKER_HOST: ~/.zshrc line 3 sets DOCKER_HOST")
        #expect(!r.text(home: "/Users/me", version: "x").contains("/Users/me"))
    }
}
