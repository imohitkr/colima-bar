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
