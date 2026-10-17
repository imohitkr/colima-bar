import Foundation
import Testing

@testable import ColimaBar

@Suite struct DiagnosticsBundleTests {
    private let redactor = Redactor(home: "/Users/jdoe", userNames: ["jdoe"])

    private func render(_ sections: [DiagnosticsSection], debug: Bool = false) -> String {
        DiagnosticsBundle.render(
            sections: sections, date: Date(timeIntervalSince1970: 0), version: "0.9.0", isDebugRun: debug,
            elapsed: 1.5, redactor: redactor)
    }

    @Test func listsFailedAndSkippedPartsWithTheirReasons() {
        let text = render([
            DiagnosticsSection(part: .tools, outcome: .ok("colima: found")),
            DiagnosticsSection(part: .engine, outcome: .skipped("the VM is not running")),
            DiagnosticsSection(part: .lima, outcome: .failed("timed out")),
        ])
        #expect(text.contains("Tools: ok"))
        #expect(text.contains("Engine: skipped (the VM is not running)"))
        #expect(text.contains("Lima: failed (timed out)"))
        #expect(text.contains("== Lima ==\nFailed: timed out."))
        #expect(text.hasPrefix(DiagnosticsBundle.notice))
    }

    @Test func theSummaryNamesADebugRun() {
        let text = render([], debug: true)
        #expect(text.contains("(debug run)"))
        #expect(!render([]).contains("debug run"))
    }

    @Test func theHomeFolderIsGoneFromEverySection() {
        let sections = DiagnosticsPart.allCases.map {
            DiagnosticsSection(part: $0, outcome: .ok("path /Users/jdoe/.colima/default"))
        }
        let text = render(sections)
        #expect(!text.contains("/Users/jdoe"))
        #expect(!text.contains("jdoe"))
        #expect(text.components(separatedBy: "~/.colima/default").count == DiagnosticsPart.allCases.count + 1)
    }

    @Test func theFileStaysWithinTheSizeLimit() {
        let big = String(repeating: "line of text\n", count: 400_000)
        let text = render([DiagnosticsSection(part: .appLog, outcome: .ok(big))])
        #expect(text.utf8.count <= DiagnosticsBundle.maxBytes)
        #expect(text.contains("[cut at"))
    }

    @Test func theFileNameUsesTheDateAndTheTimeZone() {
        let date = Date(timeIntervalSince1970: 1_776_000_000)  // 2026-04-12 13:20:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(DiagnosticsBundle.fileName(date: date, timeZone: utc) == "ColimaBar-diagnostics-20260412-132000.txt")
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        #expect(DiagnosticsBundle.fileName(date: date, timeZone: berlin) == "ColimaBar-diagnostics-20260412-152000.txt")
    }

    @Test func tailKeepsTheLastLinesAndAddsANote() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let out = DiagnosticsBundle.tail(text, lines: 3, bytes: 1_000)
        #expect(out.hasSuffix("line 8\nline 9\nline 10"))
        #expect(out.hasPrefix("[older lines cut"))
        #expect(!out.contains("line 7"))
    }

    @Test func tailKeepsAShortTextWhole() {
        #expect(DiagnosticsBundle.tail("a\nb\n", lines: 5, bytes: 100) == "a\nb")
    }

    @Test func tailCutsByBytesAtALineStart() {
        let text = (1...100).map { "row \($0)" }.joined(separator: "\n")
        let out = DiagnosticsBundle.tail(text, lines: 1_000, bytes: 50)
        #expect(out.hasPrefix("[older lines cut"))
        let body = out.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        #expect(body.first?.hasPrefix("row ") == true)
        #expect(body.joined(separator: "\n").utf8.count <= 50)
        #expect(out.hasSuffix("row 100"))
    }

    @Test func tailKeepsUTF8Whole() {
        let text = String(repeating: "é", count: 100)
        let out = DiagnosticsBundle.tail(text, lines: 10, bytes: 51)
        #expect(!out.contains("\u{FFFD}"))
        #expect(out.contains("é"))
    }

    @Test func aPartialPartShowsItsTextAndItsReason() {
        let text = render([
            DiagnosticsSection(part: .routes, outcome: .partial("context: x", "docker context ls failed"))
        ])
        #expect(text.contains("Routes: partial (docker context ls failed)"))
        #expect(text.contains("== Routes ==\ncontext: x\nPartial: docker context ls failed."))
    }

    @Test func notesShowInTheSummary() {
        let text = DiagnosticsBundle.render(
            sections: [], date: Date(timeIntervalSince1970: 0), version: "0.9.0", isDebugRun: false, elapsed: 1,
            notes: ["Mac names: not all read; check the file before you share it."], redactor: redactor)
        #expect(text.contains("Note: Mac names: not all read; check the file before you share it."))
    }

    @Test func aRegistryHostFromTheDoctorTextDoesNotReachTheFile() {
        let report = DoctorReport(
            profile: "default", date: Date(),
            results: [
                DoctorResult(
                    .credentials, .warning,
                    "credHelpers names a missing helper for 123.dkr.ecr.eu-west-1.amazonaws.com.",
                    shareDetail: "credHelpers names a missing helper for 1 registry.")
            ])
        let text = render([
            DiagnosticsSection(part: .doctor, outcome: .ok(report.text(home: "/Users/jdoe", version: "1")))
        ])
        #expect(!text.contains("amazonaws") && text.contains("1 registry"))
    }
}
