import Foundation
import Testing

@testable import ColimaBar

@Suite struct ResolverInstallerTests {
    private func run(_ status: Int32, _ out: String, new: String? = "a.test", old: String? = nil) async
        -> (ResolverInstaller.Outcome, [[String]])
    {
        let fake = FakeResolverRunner()
        fake.queue(Shell.Result(status: status, out: out))
        let outcome = await ResolverInstaller.apply(new: new, old: old, port: 25000, run: fake.runner)
        return (outcome, fake.calls)
    }

    @Test func statusZeroIsDone() async {
        #expect(await run(0, "").0 == .done)
    }

    @Test func theArgumentsAreOsascriptAndOneScript() async throws {
        let (_, calls) = await run(0, "", new: "a.test", old: "b.test")
        let args = try #require(calls.first)
        #expect(calls.count == 1 && args.count == 3 && args[0] == "osascript" && args[1] == "-e")
        let shell = try #require(ResolverFile.shellCommand(new: "a.test", old: "b.test", port: 25000))
        #expect(args[2] == ResolverFile.appleScript(shell))
        #expect(args[2].hasSuffix("with administrator privileges"))
    }

    @Test func foreignShowsInTheStatusOrTheText() async {
        #expect(await run(3, "").0 == .foreign)
        #expect(await run(1, "execution error: colimabar-foreign (3)").0 == .foreign)
    }

    @Test func aCancelIsRecognised() async {
        #expect(await run(1, "execution error: User canceled. (-128)").0 == .cancelled)
        #expect(await run(1, "0:1: execution error: Benutzer abgebrochen. (-128)").0 == .cancelled)
    }

    @Test func otherErrorsKeepTheirFirstLine() async {
        #expect(await run(1, "execution error: boom (1)\nsecond").0 == .failed("execution error: boom (1)"))
        #expect(await run(7, "").0 == .failed("status 7"))
    }

    @Test func invalidInputNeverReachesTheRunner() async {
        let (outcome, calls) = await run(0, "", new: "dev")
        #expect(outcome == .failed("The suffix or the port is not valid."))
        #expect(calls.isEmpty)
    }

    @Test func theSystemRunnerRefusesInATestProcess() async {
        let r = await ResolverInstaller.systemRun(["osascript", "-e", "return 1"])
        #expect(!r.ok)
    }

    @Test func inspectAndPrecheckReadTheFile() throws {
        let dir = NSTemporaryDirectory() + "cb-inspect-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(ResolverInstaller.inspect("a.test", dir: dir) == .missing)
        #expect(ResolverInstaller.precheck("a.test", dir: dir) == nil)
        try ResolverFile.content(port: 25000).write(toFile: dir + "/a.test", atomically: true, encoding: .utf8)
        #expect(ResolverInstaller.inspect("a.test", dir: dir) == .ours)
        #expect(ResolverInstaller.precheck("a.test", dir: dir) == nil)
        try "nameserver 1.1.1.1\n".write(toFile: dir + "/b.test", atomically: true, encoding: .utf8)
        #expect(ResolverInstaller.inspect("b.test", dir: dir) == .foreign)
        #expect(ResolverInstaller.precheck("b.test", dir: dir) == .foreign)
        symlink(dir + "/a.test", dir + "/c.test")
        #expect(ResolverInstaller.inspect("c.test", dir: dir) == .foreign)
    }
}
