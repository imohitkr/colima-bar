import Foundation
import Testing

@testable import ColimaBar

/// The install state of an `Updater` after a failure. Each test uses its own
/// `Updater` and a work folder in a temporary folder, never the real one.
/// The tests share two UserDefaults keys, so the suite runs one test at a time.
@Suite(.serialized) @MainActor struct UpdaterInstallTests {
    private let release = ReleaseInfo(
        version: "0.9.1", tag: "v0.9.1",
        page: URL(string: "https://github.com/imohitkr/colima-bar/releases/tag/v0.9.1")!,
        zip: ReleaseInfo.Asset(size: 100, sha256: String(repeating: "ab", count: 32)))

    /// An updater with a temporary work folder that holds a marker file, and
    /// a list of the notifications that it announces.
    @MainActor private final class Setup {
        let tmp = try! TempFolder()
        let updater = Updater()
        var notices: [(body: String, title: String)] = []
        var workFolder: String { "\(tmp.path)/update" }
        var marker: String { "\(workFolder)/marker" }

        init() {
            updater.updateDir = "\(tmp.path)/update"
            try? FileManager.default.createDirectory(atPath: workFolder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker, contents: Data("x".utf8))
            Defaults.remove(.recoveryPath)
            Defaults.remove(.installedVersion)
        }
    }

    private func setup() -> Setup {
        let s = Setup()
        s.updater.announce = { [unowned s] body, title, _ in s.notices.append((body, title)) }
        return s
    }

    @Test func aCancelShowsNothingAndRemovesTheWorkFolder() {
        let s = setup()
        s.updater.phase = .verifying
        s.updater.fail(.cancelled, release: release)
        #expect(s.updater.phase == .idle)
        #expect(s.notices.isEmpty)
        #expect(s.updater.fellBack == nil)
        #expect(!FileManager.default.fileExists(atPath: s.workFolder))
    }

    @Test func aFailedCheckSwitchesTheOfferAndTellsTheUser() {
        let s = setup()
        s.updater.fail(.digestMismatch, release: release)
        #expect(s.updater.fellBack != nil)
        #expect(s.notices.count == 1)
        #expect(s.notices.first?.body.contains("did not install 0.9.1") == true)
        #expect(s.notices.first?.title == "Update failed")
    }

    @Test func aNetworkFailureKeepsTheInstallOffer() {
        let s = setup()
        s.updater.fail(.network("x"), release: release)
        #expect(s.updater.fellBack == nil)
        #expect(s.notices.count == 1)
    }

    @Test func aMissingAttestationCheckAfterAPromiseKeepsTheInstallOffer() {
        let s = setup()
        s.updater.fail(.attestationUnavailable("gh did not finish the check"), release: release)
        #expect(s.updater.fellBack == nil)
        #expect(s.notices.first?.body.contains("attestation") == true)
    }

    @Test func aFailedRollbackKeepsTheWorkFolderAndRemembersTheOldBundle() {
        let s = setup()
        let old = "\(s.tmp.path)/update/unpacked/ColimaBar.app"
        try? FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        s.updater.fail(.rollbackFailed(old), release: release)
        #expect(FileManager.default.fileExists(atPath: old))
        #expect(Defaults.string(.recoveryPath) == old)
        #expect(s.notices.first?.body.contains(old) == true)
        // The next launch keeps everything while the old bundle exists...
        s.updater.cleanUp(bundle: nil, running: "/x")
        #expect(FileManager.default.fileExists(atPath: old))
        // ...and cleans up after the user moved it away.
        try? FileManager.default.removeItem(atPath: old)
        s.updater.cleanUp(bundle: nil, running: "/x")
        #expect(Defaults.string(.recoveryPath) == nil)
        #expect(!FileManager.default.fileExists(atPath: s.workFolder))
    }

    @Test func aNewWorkFolderKeepsTheOldBundleOfAFailedRollback() {
        let s = setup()
        let old = "\(s.workFolder)/unpacked/ColimaBar.app"
        try? FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        Defaults.set(old, .recoveryPath)
        s.updater.removeWorkFolder()
        #expect(FileManager.default.fileExists(atPath: old))
        // An old bundle outside the work folder does not hold it.
        Defaults.set("\(s.tmp.path)/apps/.ColimaBar-update.app", .recoveryPath)
        s.updater.removeWorkFolder()
        #expect(!FileManager.default.fileExists(atPath: s.workFolder))
        Defaults.remove(.recoveryPath)
    }

    @Test func theCleanUpRemovesLeftoverCopiesButNeverTheRunningBundle() throws {
        let s = setup()
        let apps = "\(s.tmp.path)/apps"
        let stage = "\(apps)/.ColimaBar-update.app"
        let side = "\(apps)/.ColimaBar-old.app"
        for p in [stage, side] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
        s.updater.cleanUp(bundle: "\(apps)/ColimaBar.app", running: stage)
        #expect(FileManager.default.fileExists(atPath: stage))
        #expect(!FileManager.default.fileExists(atPath: side))
        #expect(!FileManager.default.fileExists(atPath: s.workFolder))
    }

    @Test func aFailedRelaunchOfAManualCopyTellsTheUserAndDropsTheOffer() {
        let s = setup()
        s.updater.available = release
        s.updater.phase = .installing
        s.updater.relaunchDidFail()
        #expect(s.updater.phase == .idle)
        #expect(s.updater.available == nil)
        #expect(s.updater.restartPending == "0.9.1")
        #expect(s.notices.count == 1)
        #expect(s.notices.first?.body == UpdatePolicy.restartNotice(version: "0.9.1"))
    }

    @Test func aFailedRelaunchWithoutAReleaseOnlyEndsTheInstall() {
        let s = setup()
        s.updater.phase = .installing
        s.updater.relaunchDidFail()
        #expect(s.updater.phase == .idle)
        #expect(s.notices.isEmpty)
    }

    @Test func anInstallDoesNotStartForACopyThatCannotUpdateItself() {
        // The test runner is not in /Applications, so it cannot update itself.
        let s = setup()
        s.updater.available = release
        s.updater.install()
        #expect(s.updater.phase == .idle)
        #expect(s.updater.installTask == nil)
    }

    @Test func anInstallDoesNotStartAfterAFailedUpdate() {
        let s = setup()
        s.updater.available = release
        s.updater.fellBack = "the last update to this version failed"
        s.updater.install()
        #expect(s.updater.phase == .idle)
        #expect(s.updater.offer == .link("the last update to this version failed"))
    }
}
