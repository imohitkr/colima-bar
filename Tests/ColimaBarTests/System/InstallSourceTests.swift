import Foundation
import Testing

@testable import ColimaBar

@Suite struct InstallSourceTests {
    private let apps = "/Applications/ColimaBar.app"
    private let uid: UInt32 = 501

    /// A disk where everything is normal and writable, for one user.
    private func disk(
        caskroom: [String: [String]] = [:], missing: Set<String> = [], readOnly: Set<String> = [],
        notWritable: Set<String> = [], symlinks: Set<String> = [], owner: UInt32? = 501
    ) -> InstallSource.Disk {
        InstallSource.Disk(
            caskroomLinks: { caskroom[$0] ?? [] },
            exists: { path in !missing.contains(path) && (caskroom[path] != nil || !path.contains("Caskroom")) },
            isWritable: { !notWritable.contains($0) },
            isReadOnlyVolume: { readOnly.contains($0) },
            isSymlink: { symlinks.contains($0) },
            ownerUID: { _ in owner },
            uid: 501)
    }

    private func detect(
        _ path: String? = nil, version: String = "0.9.0", debug: Bool = false, _ d: InstallSource.Disk? = nil
    ) -> InstallSource {
        InstallSource.detect(bundlePath: path ?? apps, version: version, isDebug: debug, disk: d ?? disk())
    }

    @Test func aWritableInstalledCopyUpdatesItself() {
        #expect(detect() == .selfUpdate(URL(fileURLWithPath: apps)))
        let user = "\(Paths.home)/Applications/ColimaBar.app"
        #expect(detect(user) == .selfUpdate(URL(fileURLWithPath: user)))
    }

    @Test func aDebugRunNeverUpdates() {
        #expect(detect(debug: true) == .linkOnly(.debugRun))
        // The debug run wins over a Homebrew copy.
        #expect(
            detect(debug: true, disk(caskroom: ["/opt/homebrew/Caskroom/colima-bar": [apps]])) == .linkOnly(.debugRun))
    }

    @Test func aVersionThatIsNotXYZIsADevBuild() {
        for v in ["dev", "0.9.0-3-gabc123", "0.9.0-3-gabc123-dirty", "abc1234", "0.9", "0.9.0.1", "v0.9.0", ""] {
            #expect(detect(version: v) == .linkOnly(.devBuild), "\(v)")
        }
    }

    @Test func homebrewIsFoundByTheCaskroomLink() {
        let link = disk(caskroom: ["/opt/homebrew/Caskroom/colima-bar": [apps]])
        #expect(detect(apps, link) == .homebrew)
        let intel = disk(caskroom: ["/usr/local/Caskroom/colima-bar": ["/Users/x/Applications/ColimaBar.app"]])
        #expect(detect("/Users/x/Applications/ColimaBar.app", intel) == .homebrew)
    }

    @Test func homebrewIsFoundByTheCaskroomFolderForTheApplicationsCopy() {
        let folder = disk(caskroom: ["/opt/homebrew/Caskroom/colima-bar": []])
        #expect(detect(apps, folder) == .homebrew)
        // A copy in another folder is not Homebrew's when the link does not point to it.
        #expect(
            detect("\(Paths.home)/Applications/ColimaBar.app", folder)
                == .selfUpdate(URL(fileURLWithPath: "\(Paths.home)/Applications/ColimaBar.app")))
    }

    @Test func aCopyThatIsNotInstalledOnlyLinks() {
        for path in [
            "/Volumes/ColimaBar/ColimaBar.app", "\(Paths.home)/Downloads/ColimaBar.app",
            "/private/var/folders/x/AppTranslocation/Y/d/ColimaBar.app", "/tmp/build/ColimaBar.app",
        ] {
            #expect(detect(path) == .linkOnly(.notInstalled), "\(path)")
        }
    }

    @Test func aReadOnlyVolumeOnlyLinks() {
        #expect(detect(apps, disk(readOnly: ["/Applications"])) == .linkOnly(.readOnly))
    }

    @Test func aFolderOrBundleThatIsNotWritableOnlyLinks() {
        #expect(detect(apps, disk(notWritable: ["/Applications"])) == .linkOnly(.notWritable))
        #expect(detect(apps, disk(notWritable: [apps])) == .linkOnly(.notWritable))
        #expect(detect(apps, disk(owner: 0)) == .linkOnly(.notWritable))
        #expect(detect(apps, disk(symlinks: [apps])) == .linkOnly(.notWritable))
    }

    @Test func theFirstMatchingRuleWins() {
        // Not installed beats read-only.
        #expect(detect("/Volumes/x/ColimaBar.app", disk(readOnly: ["/Volumes/x"])) == .linkOnly(.notInstalled))
        // Read-only beats not writable.
        #expect(detect(apps, disk(readOnly: ["/Applications"], notWritable: ["/Applications"])) == .linkOnly(.readOnly))
        // A dev build beats Homebrew.
        #expect(
            detect(version: "dev", disk(caskroom: ["/opt/homebrew/Caskroom/colima-bar": [apps]]))
                == .linkOnly(.devBuild))
    }

    @Test func everyReasonHasText() {
        let all: [InstallSource.Reason] = [.debugRun, .devBuild, .notInstalled, .readOnly, .notWritable]
        #expect(Set(all.map(\.text)).count == all.count)
    }
}
