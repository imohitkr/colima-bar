import Testing

@testable import ColimaBar

@Suite struct CLIHelpTests {
    @Test func theHelpNamesEveryCommand() {
        for command in CLIRequest.Command.allCases {
            #expect(CLIHelp.text.contains("\n  \(command.rawValue) "), "missing \(command.rawValue)")
        }
    }

    @Test func theHelpNamesEveryExitCodeOfTheCommand() {
        for line in ["0    Done", "1    Failed", "2    Usage error", "3    Not done", "130/143  Interrupted"] {
            #expect(CLIHelp.text.contains(line))
        }
    }

    @Test func theHelpLinesAreShort() {
        for line in CLIHelp.text.split(separator: "\n") { #expect(line.count <= 100) }
    }

    @Test func theVersionLineNamesTheCommand() {
        #expect(CLIHelp.version("0.10.0") == "colimabar 0.10.0")
    }

    @Test func aUsageErrorPointsToTheHelp() {
        let text = CLIHelp.usageError("Unknown command: x.")
        #expect(text == "colimabar: Unknown command: x.\nRun `colimabar help` to see the commands.")
    }
}
