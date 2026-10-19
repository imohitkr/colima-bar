import Foundation
import Testing

@testable import ColimaBar

@Suite struct CLIExitTests {
    @Test(arguments: [(Int32(0), Int32(0)), (1, 1), (2, 3), (143, 1), (-1, 1), (127, 1)])
    func theScriptStatusBecomesAnExitCode(script: Int32, expected: Int32) {
        #expect(CLIExit.forScript(status: script) == expected)
    }

    @Test func aSignalGivesTheShellExitCode() {
        #expect(CLIExit.forSignal(SIGINT) == 130)
        #expect(CLIExit.forSignal(SIGTERM) == 143)
    }

    private func report(_ results: [DoctorResult]) -> DoctorReport {
        DoctorReport(profile: "default", date: Date(timeIntervalSince1970: 0), results: results)
    }

    @Test func aDoctorProblemFailsAndAWarningDoesNot() {
        #expect(CLIExit.forDoctor(report([.init(.tools, .problem, "x")])) == 1)
        #expect(CLIExit.forDoctor(report([.init(.tools, .warning, "x"), .init(.context, .problem, "y")])) == 1)
        #expect(CLIExit.forDoctor(report([.init(.tools, .warning, "x")])) == 0)
        #expect(CLIExit.forDoctor(report([.init(.tools, .ok, "x"), .init(.diskSpace, .skipped, "y")])) == 0)
        #expect(CLIExit.forDoctor(report([])) == 0)
    }

    @Test func aStatusIsDoneOnlyForAListedProfile() {
        #expect(CLIExit.forStatus(.running) == 0)
        #expect(CLIExit.forStatus(.stopped) == 0)
        #expect(CLIExit.forStatus(.broken) == 0)
        #expect(CLIExit.forStatus(.missing) == 1)
        #expect(CLIExit.forStatus(.notInstalled) == 1)
        #expect(CLIExit.forStatus(.unknown) == 1)
    }

    @Test func theNumbersDoNotChange() {
        #expect([CLIExit.done, CLIExit.failed, CLIExit.usage, CLIExit.locked] == [0, 1, 2, 3])
        #expect([CLIExit.interrupted, CLIExit.terminated] == [130, 143])
    }
}
