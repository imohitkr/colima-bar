import Testing

@testable import ColimaBar

@Suite struct CLIParserTests {
    private func request(_ args: [String]) -> CLIRequest? {
        guard case .run(let r) = CLIParser.parse(args) else { return nil }
        return r
    }

    private func problem(_ args: [String]) -> String? {
        guard case .usageError(let text) = CLIParser.parse(args) else { return nil }
        return text
    }

    @Test(arguments: ["status", "start", "stop", "restart", "open", "doctor", "diagnostics", "version", "help"])
    func everyCommandParses(name: String) throws {
        let command = try #require(CLIRequest.Command(rawValue: name))
        #expect(request([name]) == CLIRequest(command))
    }

    @Test func noArgumentsAndTheHelpFlagsShowTheHelp() {
        #expect(request([]) == CLIRequest(.help))
        #expect(request(["-h"]) == CLIRequest(.help))
        #expect(request(["--help"]) == CLIRequest(.help))
        #expect(request(["status", "--help"]) == CLIRequest(.help))
        #expect(request(["start", "-h"]) == CLIRequest(.help))
    }

    @Test func theVersionFlagShowsTheVersion() {
        #expect(request(["--version"]) == CLIRequest(.version))
    }

    @Test func theProfileOptionHasThreeForms() {
        #expect(request(["status", "--profile", "work"]) == CLIRequest(.status, profile: "work"))
        #expect(request(["status", "-p", "work"]) == CLIRequest(.status, profile: "work"))
        #expect(request(["status", "--profile=work"]) == CLIRequest(.status, profile: "work"))
        #expect(request(["start", "--profile=a.b_c-1"]) == CLIRequest(.start, profile: "a.b_c-1"))
    }

    @Test func theOptionsCanComeInAnyOrder() {
        #expect(request(["doctor", "--json", "-p", "work"]) == CLIRequest(.doctor, profile: "work", json: true))
        #expect(request(["doctor", "-p", "work", "--json"]) == CLIRequest(.doctor, profile: "work", json: true))
    }

    @Test func diagnosticsTakesAPath() {
        #expect(request(["diagnostics", "out.txt"]) == CLIRequest(.diagnostics, path: "out.txt"))
        #expect(
            request(["diagnostics", "-p", "work", "/tmp/x"])
                == CLIRequest(.diagnostics, profile: "work", path: "/tmp/x"))
        #expect(request(["diagnostics", "/tmp/x", "--profile", "work"]) != nil)
    }

    @Test func aDoubleDashEndsTheOptions() {
        #expect(request(["diagnostics", "--", "-odd"]) == CLIRequest(.diagnostics, path: "-odd"))
    }

    @Test func aGivenOptionTwiceIsAUsageError() {
        #expect(problem(["status", "--json", "--json"]) == "The option --json is given twice.")
        #expect(problem(["status", "-p", "a", "--profile=b"]) == "The option --profile is given twice.")
    }

    @Test func anOptionThatTheCommandDoesNotTakeIsAUsageError() {
        #expect(problem(["start", "--json"]) == "The option --json does not work with start.")
        #expect(problem(["open", "--profile", "work"]) == "The option --profile does not work with open.")
        #expect(problem(["version", "-p", "work"]) == "The option --profile does not work with version.")
        #expect(problem(["stop", "--profile=work", "--json"]) != nil)
    }

    @Test func anExtraArgumentIsAUsageError() {
        #expect(problem(["status", "extra"]) == "Unexpected argument: extra.")
        #expect(problem(["start", "work"]) == "Unexpected argument: work.")
        #expect(problem(["diagnostics", "a", "b"]) == "Unexpected argument: b.")
        #expect(problem(["help", "status"]) == "Unexpected argument: status.")
    }

    @Test func anUnknownCommandOrOptionIsAUsageError() {
        #expect(problem(["frobnicate"]) == "Unknown command: frobnicate.")
        #expect(problem(["--frobnicate"]) == "Unknown option: --frobnicate.")
        #expect(problem(["status", "--frobnicate"]) == "Unknown option: --frobnicate.")
        #expect(problem(["status", "-x"]) == "Unknown option: -x.")
    }

    @Test func aMissingProfileNameIsAUsageError() {
        #expect(problem(["status", "--profile"]) == "The option --profile needs a name.")
        #expect(problem(["status", "--profile="]) == "The option --profile needs a name.")
        #expect(problem(["status", "--profile", "--json"]) == "The option --profile needs a name.")
    }

    @Test(arguments: ["bad name", ".hidden", "..", "a/b", "ü", "a;b"])
    func aProfileNameThatTheScriptRefusesIsAUsageError(name: String) {
        let text = problem(["status", "--profile", name])
        #expect(text?.hasPrefix("The profile name is not valid") == true)
    }

    @Test func colimaNamesThatColimaReadsAsAnotherProfileAreAUsageError() {
        #expect(problem(["start", "--profile", "colima"]) == "Colima reads the name colima as default. Use default.")
        #expect(
            problem(["start", "--profile=colima-work"]) == "Colima reads the name colima-work as work. Use work.")
        #expect(problem(["start", "-p", "colima-"]) == "Colima reads the name colima- as default. Use default.")
        // A name that only starts like it is fine.
        #expect(request(["start", "-p", "colimawork"]) == CLIRequest(.start, profile: "colimawork"))
    }

    @Test func aValidNameMayStartWithAHyphenOnlyInTheEqualsForm() {
        #expect(request(["status", "--profile=-x"]) == CLIRequest(.status, profile: "-x"))
        #expect(problem(["status", "--profile", "-x"]) == "The option --profile needs a name.")
    }
}
