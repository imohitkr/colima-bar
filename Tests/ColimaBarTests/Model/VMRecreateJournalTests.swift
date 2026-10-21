import Foundation
import Testing

@testable import ColimaBar

@Suite struct VMRecreateJournalTests {
    private func journal(phase: VMRecreateJournal.Phase = .restore) -> VMRecreateJournal {
        VMRecreateJournal(
            profile: "work", from: .init(vmType: "vz", mountType: "virtiofs"),
            to: .init(vmType: "qemu", mountType: "sshfs"), folder: "/Users/me/Desktop/ColimaBar-work-1",
            created: Date(timeIntervalSince1970: 1_700_000_000), phase: phase,
            volumes: [.init(name: "pgdata", file: "pgdata-1.tar")], imagesFile: "images.tar",
            imagesSHA256: String(repeating: "ab", count: 32), images: ["nginx:1.27"])
    }

    private func read(_ j: VMSettings.Read? = nil, vm: String = "", mount: String = "") -> VMSettings.Read {
        var r = j ?? VMSettings.Read()
        r.vmType = vm
        r.mountType = mount
        return r
    }

    @Test func aJournalSurvivesAnEncodeAndADecode() throws {
        let j = journal()
        #expect(VMRecreateJournal.load(j.encoded()) == j)
        let text = String(decoding: j.encoded(), as: UTF8.self)
        #expect(text.contains("\"format\" : \"colimabar-recreate\""))
        #expect(text.contains("\"phase\" : \"restore\""))
    }

    @Test func aWrongFormatVersionOrProfileGivesNothing() throws {
        var bad = journal()
        bad.format = "other"
        #expect(VMRecreateJournal.load(bad.encoded()) == nil)
        bad = journal()
        bad.version = 2
        #expect(VMRecreateJournal.load(bad.encoded()) == nil)
        bad = journal()
        bad.profile = "../x"
        #expect(VMRecreateJournal.load(bad.encoded()) == nil)
        #expect(VMRecreateJournal.load(Data("not json".utf8)) == nil)
    }

    @Test func aJournalWithAPathInAFileNameOrABadHashGivesNothing() {
        var bad = journal()
        bad.volumes = [.init(name: "x", file: "../etc/passwd")]
        #expect(VMRecreateJournal.load(bad.encoded()) == nil)
        bad = journal()
        bad.imagesFile = "a/b.tar"
        #expect(VMRecreateJournal.load(bad.encoded()) == nil)
        bad = journal()
        bad.imagesSHA256 = "xyz"
        #expect(VMRecreateJournal.load(bad.encoded()) == nil)
    }

    @Test func theBackupPhaseMeansNothingChanged() {
        let j = journal(phase: .backup)
        #expect(VMRecreateJournal.recovery(j, now: read(), busy: false) == .nothingChanged)
        #expect(VMRecreateJournal.recovery(j, now: nil, busy: false) == .nothingChanged)
    }

    @Test func theRestorePhaseMeansARestoreIsPending() {
        let j = journal(phase: .restore)
        #expect(VMRecreateJournal.recovery(j, now: read(vm: "qemu", mount: "sshfs"), busy: false) == .restorePending)
        #expect(VMRecreateJournal.recovery(j, now: nil, busy: false) == .restorePending)
    }

    @Test func theRecreatePhaseLooksAtTheTypesOfColimaYAML() {
        let j = journal(phase: .recreate)
        #expect(VMRecreateJournal.recovery(j, now: read(vm: "qemu", mount: "sshfs"), busy: false) == .restorePending)
        #expect(VMRecreateJournal.recovery(j, now: read(), busy: false) == .nothingChanged)
        #expect(VMRecreateJournal.recovery(j, now: read(vm: "vz", mount: "virtiofs"), busy: false) == .nothingChanged)
        #expect(VMRecreateJournal.recovery(j, now: nil, busy: false) == .configMissing)
    }

    @Test func aBusyProfileHasNoRecovery() {
        for phase in [VMRecreateJournal.Phase.backup, .recreate, .restore] {
            #expect(VMRecreateJournal.recovery(journal(phase: phase), now: read(), busy: true) == nil)
        }
    }

    @Test func theFolderNameHasNoPath() {
        #expect(journal().folderName == "ColimaBar-work-1")
    }
}
