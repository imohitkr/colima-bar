import Foundation
import Testing

@testable import ColimaBar

@Suite struct IssueLinkTests {
    private let redactor = Redactor(home: "/Users/jdoe", userNames: ["jdoe"])

    private func fields(diagnostics: [String] = ["No problems"]) -> IssueLink.Fields {
        IssueLink.Fields(
            macOS: "26.0.1", colimaBar: "0.9.0", colima: ["colima 0.10.3", "lima 2.2.1", "docker 29.0.1"],
            runtime: "docker, default", diagnostics: diagnostics)
    }

    @Test func usesTheFixedHostPathAndTemplate() throws {
        let url = IssueLink.url(fields(), redactor: redactor)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.scheme == "https" && c.host == "github.com")
        #expect(c.path == "/imohitkr/colima-bar/issues/new")
        let names = (c.queryItems ?? []).map(\.name)
        #expect(names == ["template", "macos", "colimabar", "colima", "runtime", "diagnostics"])
        #expect(c.queryItems?.first?.value == "bug_report.yml")
    }

    @Test func encodesOnlyUnreservedCharactersLiterally() {
        #expect(IssueLink.encode("a b+c&d=e#f%g\nh é~-._") == "a%20b%2Bc%26d%3De%23f%25g%0Ah%20%C3%A9~-._")
    }

    @Test func theValuesComeBackUnchanged() throws {
        let text = "x+y & z=1 #2 100%\nnew line é"
        let url = IssueLink.url(fields(diagnostics: [text]), redactor: redactor)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "diagnostics" }?.value == text)
        #expect(url.absoluteString.contains("+") == false)
    }

    @Test func theFieldsGoThroughTheRedactor() {
        let url = IssueLink.url(
            fields(diagnostics: ["[problem] Path: /Users/jdoe/x token=hunter2"]), redactor: redactor)
        #expect(!url.absoluteString.contains("jdoe"))
        #expect(!url.absoluteString.contains("hunter2"))
    }

    @Test func aLongLineIsCutTo200Characters() throws {
        let url = IssueLink.url(fields(diagnostics: [String(repeating: "a", count: 500)]), redactor: redactor)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "diagnostics" }?.value?.count == 200)
    }

    @Test func aLongListDropsLinesFromTheEndAndKeepsTheVersions() throws {
        let lines = (1...200).map { "[warning] Check \($0): é détail that is quite long to fill the link up" }
        let url = IssueLink.url(fields(diagnostics: lines), redactor: redactor)
        #expect(url.absoluteString.utf8.count <= IssueLink.maxBytes)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let kept = try #require(c.queryItems?.first { $0.name == "diagnostics" }?.value)
        #expect(kept.hasSuffix(IssueLink.moreNote))
        #expect(kept.hasPrefix("[warning] Check 1:"))
        #expect(!kept.contains("Check 200"))
        #expect(c.queryItems?.first { $0.name == "colima" }?.value == "colima 0.10.3\nlima 2.2.1\ndocker 29.0.1")
        #expect(c.queryItems?.first { $0.name == "macos" }?.value == "26.0.1")
    }

    @Test func aShortListHasNoNote() throws {
        let url = IssueLink.url(fields(diagnostics: ["a", "b"]), redactor: redactor)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "diagnostics" }?.value == "a\nb")
    }

    @Test func redactsALineBeforeItCutsIt() throws {
        let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        // The token starts near column 190: a cut first would leave 10 characters, too few to know.
        let line = String(repeating: "x", count: 189) + " " + token
        let url = IssueLink.url(fields(diagnostics: [line]), redactor: redactor)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let value = try #require(c.queryItems?.first { $0.name == "diagnostics" }?.value)
        #expect(!value.contains("ghp_") && value.contains("<token>"), "\(value)")
        #expect(value.count <= IssueLink.maxLine)
    }

    @Test func aNameAtTheCutIsNotLeftInPieces() throws {
        let r = Redactor(home: "/Users/x", userNames: ["Jonathan Longname"])
        let line = String(repeating: "x ", count: 98) + "Jonathan Longname"
        let url = IssueLink.url(fields(diagnostics: [line]), redactor: r)
        #expect(!url.absoluteString.contains("Jonath") && !url.absoluteString.contains("Longn"))
    }

    // MARK: fields

    private func result(_ status: DoctorResult.Status, _ detail: String, share: String? = nil) -> DoctorResult {
        DoctorResult(.credentials, status, detail, shareDetail: share)
    }

    private func make(_ report: DoctorReport?, runtime: String = "") -> IssueLink.Fields {
        IssueLink.fields(
            report: report, versions: ToolVersions(colima: "0.10.3", lima: "2.2.1", docker: nil), macOS: "26.0.1",
            colimaBar: "0.9.0", runtime: runtime, profile: "default")
    }

    @Test func fieldsListOnlyProblemsAndWarningsWithTheirLabels() {
        let report = DoctorReport(
            profile: "default", date: Date(),
            results: [
                result(.ok, "fine"), result(.warning, "odd"), result(.problem, "broken"), result(.skipped, "n/a"),
            ])
        let f = make(report)
        #expect(f.diagnostics.count == 3)
        #expect(f.diagnostics[0] == "1 problem, 1 warning")
        #expect(f.diagnostics[1].hasPrefix("[warning] ") && f.diagnostics[1].hasSuffix("odd"))
        #expect(f.diagnostics[2].hasPrefix("[problem] ") && f.diagnostics[2].hasSuffix("broken"))
    }

    @Test func fieldsSayThereIsNoReportWhenThereIsNone() {
        #expect(make(nil).diagnostics == ["No Doctor report."])
    }

    @Test func fieldsDefaultTheRuntimeAndMarkMissingVersions() {
        let f = make(nil)
        #expect(f.runtime == "docker, default")
        #expect(f.colima == ["colima 0.10.3", "lima 2.2.1", "docker unknown"])
        #expect(make(nil, runtime: "containerd").runtime == "containerd, default")
    }

    @Test func fieldsShowNoPrivateRegistryHost() {
        let report = DoctorReport(
            profile: "default", date: Date(),
            results: [
                result(
                    .warning, "credHelpers names a missing helper for 123.dkr.ecr.eu-west-1.amazonaws.com.",
                    share: "credHelpers names a missing helper for 1 registry.")
            ])
        let f = make(report)
        #expect(!f.diagnostics.joined().contains("amazonaws"))
        #expect(f.diagnostics.joined().contains("1 registry"))
    }
}
