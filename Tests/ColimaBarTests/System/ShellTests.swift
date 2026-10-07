import Foundation
import Testing

@testable import ColimaBar

@Suite struct ShellTests {
    @Test func quoteKeepsEveryWordLiteral() {
        #expect(Shell.quote("plain") == "'plain'")
        #expect(Shell.quote("/Users/a b/ColimaBar.app") == "'/Users/a b/ColimaBar.app'")
        #expect(Shell.quote("it's") == "'it'\\''s'")
        #expect(Shell.quote("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test func terminalScriptPicksTheApp() {
        let iTerm = Shell.terminalScript("echo hi", iTerm: true)
        #expect(iTerm.contains("tell application \"iTerm\""))
        #expect(iTerm.contains("write text \"echo hi\""))
        let terminal = Shell.terminalScript("echo hi", iTerm: false)
        #expect(terminal.contains("tell application \"Terminal\""))
        #expect(terminal.contains("do script \"echo hi\""))
    }

    @Test func terminalScriptEscapesQuotesAndBackslashes() {
        let script = Shell.terminalScript(#"echo "a\b""#, iTerm: false)
        #expect(script.contains(#"do script "echo \"a\\b\"""#))
    }

    @Test func colimaCallsGetTheColimaFolderInColimaHome() {
        let inherited = ProcessInfo.processInfo.environment
        for args in [["colima", "list", "-j"], [Paths.ctl, "start"]] {
            let env = Shell.environment(for: args, colimaHome: { "/data/colima" })
            #expect(env["COLIMA_HOME"] == "/data/colima", "\(args)")
            // XDG_CONFIG_HOME is not pinned: COLIMA_HOME chooses the folder.
            #expect(env["XDG_CONFIG_HOME"] == inherited["XDG_CONFIG_HOME"], "\(args)")
            #expect(env["DOCKER_HOST"] == nil)
        }
        // Other tools keep the inherited value, and no folder is made for them.
        let docker = Shell.environment(
            for: ["docker", "context", "show"],
            colimaHome: {
                Issue.record("colimaHome ran for docker")
                return ""
            })
        #expect(docker["COLIMA_HOME"] == inherited["COLIMA_HOME"])
        #expect(docker["PATH"] == Shell.searchPath)
    }

    @Test func returnsAllOutput() async {
        let r = await Shell.run(["sh", "-c", "i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done"])
        #expect(r.ok)
        let lines = r.out.split(separator: "\n")
        #expect(lines.count == 2000)
        #expect(lines.last == "line1999")
    }

    @Test func orphanHoldingThePipeDoesNotHang() async {
        let start = Date()
        let r = await Shell.run(["sh", "-c", "sleep 5 & echo hi"])
        #expect(r.ok)
        #expect(r.out == "hi\n")
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
