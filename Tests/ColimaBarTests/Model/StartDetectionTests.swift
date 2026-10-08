import Foundation
import Testing

@testable import ColimaBar

@Suite struct StartDetectionTests {
    @Test func foregroundSupervisorIsNotAStart() {
        #expect(!ColimaModel.isStartInProgress(command: "/opt/homebrew/bin/colima start -f\n", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "colima start --foreground", profile: "default"))
    }

    @Test func matchesStartsForTheProfile() {
        #expect(ColimaModel.isStartInProgress(command: "/opt/homebrew/bin/colima start\n", profile: "default"))
        #expect(ColimaModel.isStartInProgress(command: "colima start --profile work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima restart -p work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start work --cpu 4", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start --profile=work", profile: "work"))
    }

    @Test func skipsTheValueOfAFlag() {
        #expect(ColimaModel.isStartInProgress(command: "colima start --cpu 4 work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start -c 4 work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start -m 2.5 -d 100 work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start --mount-type virtiofs work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start --cpu 4", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "colima start --cpu 4 work", profile: "default"))
        // A flag with no value does not hide the profile.
        #expect(ColimaModel.isStartInProgress(command: "colima start --kubernetes work", profile: "work"))
        // `--flag=value` is one word.
        #expect(ColimaModel.isStartInProgress(command: "colima start --cpu=4 work", profile: "work"))
    }

    @Test func readsTheProfileFlagInAllForms() {
        #expect(ColimaModel.isStartInProgress(command: "colima start -p=work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start --profile=work", profile: "work"))
        // The flag wins over a word.
        #expect(ColimaModel.isStartInProgress(command: "colima start other --profile work", profile: "work"))
        #expect(!ColimaModel.isStartInProgress(command: "colima start work -p other", profile: "work"))
    }

    @Test func readsTheNamesAsColimaDoes() {
        // Colima reads "colima" as default and removes a "colima-" prefix.
        #expect(ColimaModel.isStartInProgress(command: "colima start colima-work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start -p colima-work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima start colima", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "colima start colima", profile: "colima"))
    }

    @Test func aForcedRestartCounts() {
        // For `colima restart`, -f means --force.
        #expect(ColimaModel.isStartInProgress(command: "colima restart -f work", profile: "work"))
        #expect(ColimaModel.isStartInProgress(command: "colima restart --force", profile: "default"))
    }

    @Test func theValueFlagsMatchTheScript() throws {
        let script = try String(
            contentsOf: ScriptSandbox.repo.appendingPathComponent("scripts/colima-ctl.sh"), encoding: .utf8)
        let line = try #require(
            script.components(separatedBy: "\n").first {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("-a|--arch|")
            })
        let flags = line.trimmingCharacters(in: .whitespaces).dropLast().split(separator: "|").map(String.init)
        #expect(Set(flags) == ColimaModel.startValueFlags)
        #expect(flags.count == ColimaModel.startValueFlags.count)
    }

    @Test func ignoresOtherProfilesAndCommands() {
        #expect(!ColimaModel.isStartInProgress(command: "colima start --profile work", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "colima status", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "vim colima start notes", profile: "default"))
    }

    @Test func pgrepOnlyMatchesThisUser() {
        #expect(ColimaModel.pgrepArguments(uid: 501) == ["-U", "501", "-f", "colima (start|restart)"])
    }
}
