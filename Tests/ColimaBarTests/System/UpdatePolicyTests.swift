import Foundation
import Testing

@testable import ColimaBar

@Suite struct UpdatePolicyTests {
    @Test func nothingBusyDoesNotBlock() {
        #expect(UpdatePolicy.blocker(UpdatePolicy.Activity()) == nil)
    }

    @Test func eachKindOfWorkBlocksWithItsOwnReason() {
        var reasons: [String] = []
        let cases: [UpdatePolicy.Activity] = [
            .init(busyLabels: ["Restarting"]), .init(transfers: 1), .init(wakes: 1), .init(doctorRunning: true),
            .init(savingDiagnostics: true),
        ]
        for a in cases {
            let why = UpdatePolicy.blocker(a)
            #expect(why != nil)
            reasons.append(why ?? "")
        }
        #expect(Set(reasons).count == cases.count)
        #expect(reasons[0].contains("restarting"))
    }

    @Test func comparesTheVersions() {
        #expect(UpdatePolicy.decision(running: "0.9.0", latest: "0.9.1") == .newer)
        #expect(UpdatePolicy.decision(running: "0.9.0", latest: "0.10.0") == .newer)
        #expect(UpdatePolicy.decision(running: "0.9.0", latest: "0.9.0") == .upToDate)
        #expect(UpdatePolicy.decision(running: "0.9.1", latest: "0.9.0") == .upToDate)
        #expect(UpdatePolicy.decision(running: "dev", latest: "0.9.0") == .devBuild)
        #expect(UpdatePolicy.decision(running: "abc1234", latest: "0.9.0") == .devBuild)
        // A build after a tag still counts as that version.
        #expect(UpdatePolicy.decision(running: "0.9.0-3-gabc", latest: "0.9.1") == .newer)
    }

    @Test func needsRoomForTheZipAndTheUnpackedApp() {
        let zip = 2_000_000
        let need = Int64(zip) + 2 * Int64(UpdatePolicy.maxUnpackedBytes)
        #expect(UpdatePolicy.hasRoom(free: need, zipSize: zip))
        #expect(!UpdatePolicy.hasRoom(free: need - 1, zipSize: zip))
    }

    @Test func limitsAreInsideWhatTheDesignSays() {
        #expect(UpdatePolicy.maxZipBytes == 50 * 1024 * 1024)
        #expect(UpdatePolicy.maxUnpackedBytes == 100 * 1024 * 1024)
        #expect(UpdatePolicy.maxWait == 120)
    }

    // MARK: the button, the guards and the follow-up of a failure

    private let bundle = URL(fileURLWithPath: "/Applications/ColimaBar.app")

    @Test func aSelfUpdatingCopyWithAZipOffersTheInstall() {
        #expect(UpdatePolicy.offer(source: .selfUpdate(bundle), hasZip: true, fellBack: nil) == .install)
    }

    @Test func aSelfUpdatingCopyWithoutAZipOffersTheReleasePage() {
        let offer = UpdatePolicy.offer(source: .selfUpdate(bundle), hasZip: false, fellBack: nil)
        #expect(offer == .link("this release has no download that ColimaBar can verify"))
    }

    @Test func aFailedUpdateOffersTheReleasePageForEverySource() {
        for source in [InstallSource.selfUpdate(bundle), .homebrew, .linkOnly(.notInstalled)] {
            let offer = UpdatePolicy.offer(source: source, hasZip: true, fellBack: "it failed")
            #expect(offer == .link("it failed"))
        }
    }

    @Test func homebrewAndLinkOnlyCopiesKeepTheirOffer() {
        #expect(UpdatePolicy.offer(source: .homebrew, hasZip: true, fellBack: nil) == .homebrew)
        #expect(
            UpdatePolicy.offer(source: .linkOnly(.readOnly), hasZip: true, fellBack: nil)
                == .link(InstallSource.Reason.readOnly.text))
    }

    @Test func anInstallStartsOnlyForAnIdleSelfUpdatingCopyWithAZip() {
        func target(
            debug: Bool = false, idle: Bool = true, fellBack: String? = nil,
            source: InstallSource? = nil, zip: Bool = true
        ) -> URL? {
            UpdatePolicy.installTarget(
                isDebug: debug, isIdle: idle, fellBack: fellBack, source: source ?? InstallSource.selfUpdate(bundle),
                hasZip: zip)
        }
        #expect(target() == bundle)
        #expect(target(debug: true) == nil)
        #expect(target(idle: false) == nil)
        #expect(target(fellBack: "failed") == nil)
        #expect(target(source: .homebrew) == nil)
        #expect(target(source: .linkOnly(.notWritable)) == nil)
        #expect(target(zip: false) == nil)
    }

    @Test func aCancelShowsNothingAndChangesNoOffer() {
        let plan = UpdatePolicy.afterFailure(.cancelled)
        #expect(!plan.notify)
        #expect(plan.fellBack == nil)
    }

    @Test func aFailureShowsAnAlertAndSwitchesToTheReleasePageOnlyForAVerdict() {
        #expect(UpdatePolicy.afterFailure(.network("x")).notify)
        #expect(UpdatePolicy.afterFailure(.network("x")).fellBack == nil)
        #expect(UpdatePolicy.afterFailure(.attestationUnavailable("x")).fellBack == nil)
        #expect(UpdatePolicy.afterFailure(.digestMismatch).notify)
        #expect(UpdatePolicy.afterFailure(.digestMismatch).fellBack != nil)
        #expect(UpdatePolicy.afterFailure(.rollbackFailed("/x")).fellBack != nil)
    }

    @Test func aBusyActionWithoutALabelHasNoEmptyParentheses() {
        #expect(UpdatePolicy.blocker(.init(busyLabels: [""])) == "A VM action is running")
    }

    @Test func aRefusedCheckNamesTheRateLimit() {
        #expect(UpdatePolicy.checkProblem(status: 403).contains("rate limit"))
        #expect(UpdatePolicy.checkProblem(status: 429).contains("rate limit"))
        #expect(UpdatePolicy.checkProblem(status: 500).contains("500"))
        #expect(UpdatePolicy.checkProblem(status: nil).contains("didn't answer"))
    }

    @Test func theRestartNoticeTellsTheUserWhatToDo() {
        let text = UpdatePolicy.restartNotice(version: "0.9.1")
        #expect(text.contains("0.9.1"))
        #expect(text.contains("Quit ColimaBar"))
    }

    @Test func leftoverCopiesAreBesideTheBundleAndNeverTheBundleItself() {
        let names = UpdatePolicy.leftovers(bundle: "/Applications/ColimaBar.app")
        #expect(names == ["/Applications/.ColimaBar-update.app", "/Applications/.ColimaBar-old.app"])
        #expect(
            !UpdatePolicy.leftovers(bundle: "/Applications/.ColimaBar-update.app")
                .contains("/Applications/.ColimaBar-update.app"))
    }
}
