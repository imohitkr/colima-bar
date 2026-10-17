import Foundation
import Testing

@testable import ColimaBar

@Suite struct DiagnosticsProbeTests {
    private func text(_ o: DiagnosticsProbe.Outcome) -> String {
        if case .ok(let t) = o { return t }
        return "\(o)"
    }

    @Test func tailOfALargeFileReadsOnlyTheEnd() throws {
        let dir = try TempFolder()
        let path = dir.path + "/big.log"
        let lines = (1...50_000).map { "entry number \($0)" }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let out = text(DiagnosticsProbe.tail(path: path, lines: 5, bytes: 4_096))
        #expect(out.hasSuffix("entry number 49999\nentry number 50000"))
        #expect(!out.contains("entry number 1\n"))
        #expect(out.hasPrefix("[older lines cut"))
        #expect(out.split(separator: "\n").count == 6)
    }

    @Test func tailStartsAtALineStartWhenTheByteLimitCutsTheFile() throws {
        let dir = try TempFolder()
        let path = dir.path + "/a.log"
        try (1...1_000).map { "row \($0)" }.joined(separator: "\n").write(
            toFile: path, atomically: true, encoding: .utf8)
        let out = text(DiagnosticsProbe.tail(path: path, lines: 10_000, bytes: 100))
        let body = out.split(separator: "\n").dropFirst()
        #expect(body.allSatisfy { $0.hasPrefix("row ") })
        #expect(out.hasSuffix("row 1000"))
    }

    @Test func tailOfASmallFileIsTheFileWithoutANote() throws {
        let dir = try TempFolder()
        let path = dir.path + "/s.log"
        try "one\ntwo\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(DiagnosticsProbe.tail(path: path, lines: 10, bytes: 1_000) == .ok("one\ntwo"))
    }

    @Test func aMissingFileIsSkippedNotFailed() throws {
        let dir = try TempFolder()
        #expect(
            DiagnosticsProbe.tail(path: dir.path + "/none.log", lines: 1, bytes: 10)
                == .skipped("the file does not exist"))
    }

    @Test func writesAPrivateFileAndReplacesAnOldOne() throws {
        let dir = try TempFolder()
        let url = URL(fileURLWithPath: dir.path + "/d.txt")
        try DiagnosticsProbe.write("first", to: url)
        try DiagnosticsProbe.write("second", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["d.txt"])
    }

    @Test func aWriteToAMissingFolderFails() throws {
        let dir = try TempFolder()
        let url = URL(fileURLWithPath: dir.path + "/no/such/d.txt")
        #expect(throws: (any Error).self) { try DiagnosticsProbe.write("x", to: url) }
    }

    @Test func environmentNamesShowSetOrNotSetNeverTheValue() {
        let lines = DiagnosticsProbe.environmentNames(["COLIMA_HOME": "/secret/place", "LIMA_HOME": ""])
        #expect(
            lines == ["COLIMA_HOME: set", "LIMA_HOME: not set", "XDG_CONFIG_HOME: not set", "DOCKER_CONFIG: not set"])
    }

    @Test func failureNamesTheReason() {
        #expect(DiagnosticsProbe.failure(Shell.Result(status: -1, out: "")) == "not found")
        #expect(DiagnosticsProbe.failure(Shell.Result(status: 15, out: "")) == "timed out")
        #expect(DiagnosticsProbe.failure(Shell.Result(status: 3, out: "")) == "exit 3")
    }

    @Test func toolsTextShowsMissingToolsAndVersions() {
        let t = DoctorInputs.Tools(
            colimaPath: "/opt/homebrew/bin/colima", limactlPath: nil, dockerPath: nil,
            versions: ToolVersions(colima: "0.10.3", lima: nil, macOS: "26.0.1"))
        #expect(
            DiagnosticsProbe.toolsText(t)
                == "colima: /opt/homebrew/bin/colima, version 0.10.3\nlimactl: not found\ndocker: not found\nmacOS: 26.0.1"
        )
    }

    @Test func aMissingToolIsNotFoundAndANonExecutableOneIsNamed() {
        #expect(DiagnosticsProbe.failure(status: 127) == "not found")
        #expect(DiagnosticsProbe.failure(status: -1) == "not found")
        #expect(DiagnosticsProbe.failure(status: 126) == "not executable")
        #expect(DiagnosticsProbe.failure(status: 15) == "timed out")
        #expect(DiagnosticsProbe.failure(status: 1) == "exit 1")
    }

    @Test func aFailureCarriesTheLastLineOfTheOutputCutTo200Characters() {
        let out = "first\n\nlima: instance is broken\n"
        #expect(DiagnosticsProbe.failure(status: 1, output: out) == "exit 1: lima: instance is broken")
        let long = String(repeating: "e", count: 500)
        let why = DiagnosticsProbe.failure(status: 1, output: "x\n" + long)
        #expect(why == "exit 1: " + String(repeating: "e", count: 200))
    }

    @Test func aRealToolThatFailsGivesItsReason() async {
        let notFound = await DiagnosticsProbe.command(["colimabar-no-such-tool-xyz"], timeout: 5)
        guard case .failed(let why) = notFound else {
            Issue.record("\(notFound)")
            return
        }
        #expect(why.hasPrefix("not found"))
        let exit = await DiagnosticsProbe.command(["/bin/sh", "-c", "echo oops >&2; exit 3"], timeout: 5)
        #expect(exit == .failed("exit 3: oops"))
    }

    @Test func anUnreadableCrashFolderIsAFailureNotNoCrashes() throws {
        let dir = try TempFolder()
        let locked = dir.path + "/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        let out = DiagnosticsProbe.crashReports(in: [locked], now: Date())
        guard case .failed(let why) = out else {
            Issue.record("\(out)")
            return
        }
        #expect(why.contains("cannot be read"))
    }

    @Test func aMissingCrashFolderMeansNoCrashes() throws {
        let dir = try TempFolder()
        let out = DiagnosticsProbe.crashReports(in: [dir.path + "/none", dir.path + "/none/Retired"], now: Date())
        guard case .ok(let text) = out else {
            Issue.record("\(out)")
            return
        }
        #expect(text.hasPrefix("No crash reports"))
    }

    @Test func aCrashReportThatCannotBeReadMakesThePartPartial() throws {
        let dir = try TempFolder()
        let name = "ColimaBar-2026-10-01-120000.ips"
        let file = dir.path + "/" + name
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2)) ?? Date()
        let out = DiagnosticsProbe.crashReports(in: [dir.path], now: now)
        guard case .partial(let text, let why) = out else {
            Issue.record("\(out)")
            return
        }
        #expect(text.contains(name) && why.contains("cannot be read"))
    }

    @Test func aWriteToAMissingFolderFailsWithItsReasonAndLeavesNoFile() throws {
        let dir = try TempFolder()
        let url = URL(fileURLWithPath: dir.path + "/missing/out.txt")
        #expect(throws: (any Error).self) { try DiagnosticsProbe.write("x", to: url) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == [])
    }
}
