import Foundation
import Testing

@testable import ColimaBar

@MainActor @Suite struct ColimaModelComposeTests {
    @Test func aDebugRunDoesNotRunCompose() async {
        let model = ColimaModel(profile: "work", readOnly: true)
        let project = ComposeProject(
            name: "web", directory: "/tmp", configFiles: ["/tmp/compose.yaml"], environmentFiles: [])
        model.compose(.up, project: project)
        #expect(model.composeBusy.isEmpty)
        #expect(model.composeOutput.isEmpty)
    }

    @Test func composeRunsOnlyWhenNothingStopsIt() {
        #expect(ColimaModel.mayRunCompose(updateRestarting: false, isDebug: false, projectBusy: false))
        #expect(!ColimaModel.mayRunCompose(updateRestarting: true, isDebug: false, projectBusy: false))
        #expect(!ColimaModel.mayRunCompose(updateRestarting: false, isDebug: true, projectBusy: false))
        #expect(!ColimaModel.mayRunCompose(updateRestarting: false, isDebug: false, projectBusy: true))
    }

    @Test func noticesAreTheLinesWithTheNotifyPrefix() {
        let out = "a\nCOLIMABAR_NOTIFY:first\n COLIMABAR_NOTIFY:spoof\nCOLIMABAR_NOTIFY:second\n"
        #expect(ColimaModel.notices(in: out) == ["first", "second"])
        #expect(ColimaModel.notices(in: "") == [])
    }

    @Test func theOutputKeepsTheLastLinesAndNoNotices() {
        let out = (1...300).map { "line \($0)" }.joined(separator: "\n") + "\nCOLIMABAR_NOTIFY:failed\n"
        let lines = ColimaModel.composeLines(in: out)
        #expect(lines.count == ColimaModel.composeOutputLimit)
        #expect(lines.first == "line 101")
        #expect(lines.last == "line 300")
    }

    @Test func aShortOutputIsKeptWholeWithTheSpoofedNoticeLine() {
        #expect(ColimaModel.composeLines(in: "a\n COLIMABAR_NOTIFY:x\nb\n") == ["a", " COLIMABAR_NOTIFY:x", "b"])
        #expect(ColimaModel.composeLines(in: "") == [])
    }

    @Test func aProjectKeyHasTheProfileSoTwoProfilesDoNotShareState() {
        #expect(ColimaModel.composeKey(profile: "work", name: "web") == "work/web")
        #expect(
            ColimaModel.composeKey(profile: "work", name: "web") != ColimaModel.composeKey(profile: "dev", name: "web"))
    }

    @Test(arguments: [Int32(9), 15, 143])
    func aStopByTheTimeLimitIsReportedAsATimeout(status: Int32) {
        #expect(ColimaModel.composeTimedOut(status: status))
        let text = ColimaModel.composeFailureNotice(verb: .pull, name: "web", status: status, scriptNotified: false)
        #expect(text == "Compose pull for web timed out after 15 minutes and was stopped.")
    }

    @Test func aFailureGivesTheExitCodeAndNoOutputText() {
        #expect(
            ColimaModel.composeFailureNotice(verb: .up, name: "web", status: 1, scriptNotified: false)
                == "Compose up failed for web (exit 1).")
    }

    @Test func aWorkingRunACancelAndAScriptNoticeGiveNoExtraNotice() {
        #expect(ColimaModel.composeFailureNotice(verb: .down, name: "web", status: 0, scriptNotified: false) == nil)
        #expect(ColimaModel.composeFailureNotice(verb: .down, name: "web", status: 2, scriptNotified: false) == nil)
        #expect(ColimaModel.composeFailureNotice(verb: .down, name: "web", status: 1, scriptNotified: true) == nil)
    }
}
