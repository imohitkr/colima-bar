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

    @Test func ignoresOtherProfilesAndCommands() {
        #expect(!ColimaModel.isStartInProgress(command: "colima start --profile work", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "colima status", profile: "default"))
        #expect(!ColimaModel.isStartInProgress(command: "vim colima start notes", profile: "default"))
    }

    @Test func pgrepOnlyMatchesThisUser() {
        #expect(ColimaModel.pgrepArguments(uid: 501) == ["-U", "501", "-f", "colima (start|restart)"])
    }
}
