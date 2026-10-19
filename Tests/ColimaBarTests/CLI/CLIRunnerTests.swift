import Foundation
import Testing

@testable import ColimaBar

/// Only the commands that touch nothing run here: help, version and usage
/// errors. The other commands read or change the real Mac.
@MainActor @Suite struct CLIRunnerTests {
    /// Collects what the command writes.
    @MainActor private final class Capture {
        var out: [String] = []
        var err: [String] = []
        var output: CLIOutput {
            CLIOutput(out: { self.out.append($0) }, err: { self.err.append($0) }, isTerminal: false)
        }
    }

    @Test func helpShowsTheHelpOnStdoutAndExitsWithZero() async {
        let c = Capture()
        #expect(await CLIRunner.run(["help"], output: c.output) == 0)
        #expect(c.out == [CLIHelp.text] && c.err.isEmpty)
    }

    @Test func noArgumentsShowTheHelp() async {
        let c = Capture()
        #expect(await CLIRunner.run([], output: c.output) == 0)
        #expect(c.out == [CLIHelp.text])
    }

    @Test func versionShowsTheVersionOfTheApp() async {
        let c = Capture()
        #expect(await CLIRunner.run(["version"], output: c.output) == 0)
        #expect(c.out == ["colimabar \(AppDelegate.version)"])
        let flag = Capture()
        #expect(await CLIRunner.run(["--version"], output: flag.output) == 0)
        #expect(flag.out == c.out)
    }

    @Test func aUsageErrorGoesToStderrAndExitsWithTwo() async {
        let c = Capture()
        #expect(await CLIRunner.run(["frobnicate"], output: c.output) == 2)
        #expect(c.out.isEmpty)
        #expect(c.err == [CLIHelp.usageError("Unknown command: frobnicate.")])
    }

    @Test func aBadProfileNameExitsWithTwoBeforeAnythingRuns() async {
        let c = Capture()
        #expect(await CLIRunner.run(["start", "--profile", "colima-work"], output: c.output) == 2)
        #expect(c.out.isEmpty && c.err.count == 1)
    }

    @Test func theNoticesOfTheScriptAreTheLinesWithTheMarker() {
        let output = """
            started
            COLIMABAR_NOTIFY:Colima did not start. See the log.
            other text
            COLIMABAR_NOTIFY:Second line.
            """
        #expect(
            CLIRunner.notifications(in: output) == ["Colima did not start. See the log.", "Second line."])
        #expect(CLIRunner.notifications(in: "").isEmpty)
    }
}
