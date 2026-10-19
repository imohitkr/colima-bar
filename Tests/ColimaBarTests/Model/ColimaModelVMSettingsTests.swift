import CryptoKit
import Foundation
import Testing

@testable import ColimaBar

/// The staged file of `ColimaModel.applyVMSettings`, with files in a temporary
/// folder. The tests never touch the real colima.yaml.
@Suite struct ColimaModelVMSettingsTests {
    private let template = ColimaTemplate.colima0103

    private func files() throws -> (folder: TempFolder, config: String, staged: String) {
        let folder = try TempFolder()
        let config = folder.path + "/colima.yaml"
        try template.write(toFile: config, atomically: true, encoding: .utf8)
        return (folder, config, folder.path + "/state/colima.work.yaml.new")
    }

    @Test func theStagedFileHasTheNewTextAndTheShaOfTheOldFile() throws {
        let f = try files()
        let staged = try #require(
            try ColimaModel.stageVMSettings(
                VMSettingsChange(dnsServers: ["1.1.1.1"]), configPath: f.config, stagedPath: f.staged))
        #expect(staged.path == f.staged)
        #expect(staged.sha == SHA256.hash(data: Data(template.utf8)).map { String(format: "%02x", $0) }.joined())
        let text = try String(contentsOfFile: f.staged, encoding: .utf8)
        #expect(VMSettings.read(text).dnsServers == ["1.1.1.1"])
        // The old file stays as it is.
        #expect(try String(contentsOfFile: f.config, encoding: .utf8) == template)
    }

    @Test func theStagedFileAndItsFolderArePrivate() throws {
        let f = try files()
        _ = try ColimaModel.stageVMSettings(
            VMSettingsChange(mountInotify: true), configPath: f.config, stagedPath: f.staged)
        let fm = FileManager.default
        let file = try fm.attributesOfItem(atPath: f.staged)[.posixPermissions] as? Int
        let dir = try fm.attributesOfItem(atPath: f.folder.path + "/state")[.posixPermissions] as? Int
        #expect(file == 0o600 && dir == 0o700)
    }

    @Test func aChangeThatMatchesTheFileStagesNothing() throws {
        let f = try files()
        let staged = try ColimaModel.stageVMSettings(
            VMSettingsChange(dnsServers: [], portForwarder: "ssh"), configPath: f.config, stagedPath: f.staged)
        #expect(staged == nil)
        #expect(!FileManager.default.fileExists(atPath: f.staged))
    }

    @Test func aProblemStopsBeforeAnyFileIsWritten() throws {
        let f = try files()
        #expect(throws: VMSettingsFailure.self) {
            try ColimaModel.stageVMSettings(
                VMSettingsChange(dnsServers: ["not-an-ip"]), configPath: f.config, stagedPath: f.staged)
        }
        #expect(!FileManager.default.fileExists(atPath: f.staged))
    }

    @Test func anOldStagedFileOrLinkIsReplaced() throws {
        let f = try files()
        try FileManager.default.createDirectory(atPath: f.folder.path + "/state", withIntermediateDirectories: true)
        let target = f.folder.path + "/target"
        try "keep".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: f.staged, withDestinationPath: target)
        _ = try ColimaModel.stageVMSettings(
            VMSettingsChange(mountInotify: true), configPath: f.config, stagedPath: f.staged)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
        #expect(try String(contentsOfFile: f.staged, encoding: .utf8).contains("mountInotify: true"))
    }

    @Test func aFormThatTheEditorRefusesThrowsItsKey() throws {
        let folder = try TempFolder()
        let config = folder.path + "/colima.yaml"
        try "network:\n  dns: &a [1.1.1.1]\n".write(toFile: config, atomically: true, encoding: .utf8)
        #expect(throws: ColimaYAML.Failure.unsupported("network.dns")) {
            try ColimaModel.stageVMSettings(
                VMSettingsChange(dnsServers: ["8.8.8.8"]), configPath: config, stagedPath: folder.path + "/s/x.new")
        }
    }

    @Test func theStagedPathIsInTheStateFolderWithTheNameThatTheScriptExpects() {
        #expect(Paths.stagedConfig("work") == "\(Paths.cacheDir)/colima.work.yaml.new")
    }

    @Test func aFileThatDiffersFromTheBaselineIsNotStaged() throws {
        let f = try files()
        #expect(throws: VMSettingsFailure.changedOutside) {
            try ColimaModel.stageVMSettings(
                VMSettingsChange(dnsServers: ["1.1.1.1"]), configPath: f.config, stagedPath: f.staged,
                baselineSHA: ColimaModel.configSHA(Data("cpu: 4\n".utf8)))
        }
        #expect(!FileManager.default.fileExists(atPath: f.staged))
    }

    @Test func aFileThatMatchesTheBaselineIsStaged() throws {
        let f = try files()
        let staged = try ColimaModel.stageVMSettings(
            VMSettingsChange(dnsServers: ["1.1.1.1"]), configPath: f.config, stagedPath: f.staged,
            baselineSHA: ColimaModel.configSHA(Data(template.utf8)))
        #expect(staged?.path == f.staged)
    }

    @Test func aFolderAtTheStagedPathFailsWithThePathAndTheReason() throws {
        let f = try files()
        try FileManager.default.createDirectory(atPath: f.staged, withIntermediateDirectories: true)
        do {
            _ = try ColimaModel.stageVMSettings(
                VMSettingsChange(mountInotify: true), configPath: f.config, stagedPath: f.staged)
            Issue.record("A folder at the staged path must fail.")
        } catch let failure as VMSettingsFailure {
            guard case .notWritten(let path, let reason) = failure else {
                Issue.record("Wrong failure: \(failure)")
                return
            }
            #expect(path == f.staged && !reason.isEmpty)
            #expect(failure.localizedDescription.contains(f.staged))
        }
        #expect(FileManager.default.fileExists(atPath: f.staged))
    }

    @Test func theConfigShaIsTheSha256OfTheBytes() {
        #expect(
            ColimaModel.configSHA(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func anApplyNeedsNoUpdateNoDebugRunAnEditAndAFreeProfile() {
        func may(update: Bool = false, debug: Bool = false, empty: Bool = false, busy: Bool = false) -> Bool {
            ColimaModel.mayApplyVMSettings(updateRestarting: update, isDebug: debug, changeIsEmpty: empty, busy: busy)
        }
        #expect(may())
        #expect(!may(update: true))
        #expect(!may(debug: true))
        #expect(!may(empty: true))
        #expect(!may(busy: true))
    }

    @Test func onlyTheOutcomesThatChangedTheFileMakeThePageReload() {
        #expect(VMApplyOutcome.applied.reloadsForm)
        #expect(VMApplyOutcome.alreadyThere.reloadsForm)
        #expect(VMApplyOutcome.changedOutside.reloadsForm)
        #expect(!VMApplyOutcome.skipped.reloadsForm)
        #expect(!VMApplyOutcome.failed.reloadsForm)
    }

    @Test func theAddressCheckRunsOnlyForAnAddressThatIsMissingAndNotGivenUp() {
        #expect(ColimaModel.needsAddressCheck(address: true, ipAddress: "", unavailable: false))
        #expect(!ColimaModel.needsAddressCheck(address: true, ipAddress: "192.168.64.2", unavailable: false))
        #expect(!ColimaModel.needsAddressCheck(address: true, ipAddress: "", unavailable: true))
        #expect(!ColimaModel.needsAddressCheck(address: false, ipAddress: "", unavailable: false))
    }
}
