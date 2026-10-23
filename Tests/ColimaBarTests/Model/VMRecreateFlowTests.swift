import Foundation
import Testing

@testable import ColimaBar

@Suite @MainActor struct VMRecreateFlowTests {
    /// The fake steps: they record their calls and answer from these values.
    @MainActor final class Fake {
        var calls: [String] = []
        var saved: [VMRecreateJournal] = []
        var summary: VolumeBackupBatch.Summary? = .init(
            done: [.init(name: "a", file: "a-1.tar", bytes: 10), .init(name: "b", file: "b-1.tar", bytes: 10)],
            started: true)
        var imageSave: Result<(bytes: Int64, sha256: String), VolumeBackupRunner.Failure> = .success(
            (100, String(repeating: "cd", count: 32)))
        var recreate = Shell.Result(status: 0, out: "")
        var types: (vmType: String, mountType: String)? = ("vz", "virtiofs")
        var ready = true
        /// The answers of `stopReason` after the recreate (the restore).
        var stopReasons: [VolumeTransferStop?] = []
        /// The answers of `stopReason` before the recreate.
        var preStops: [VolumeTransferStop?] = []
        /// The user clicks Cancel after the first call that starts with this text.
        var cancelAfter: String?
        var journalWorks = true
        /// The user clicked Cancel before the flow started.
        var cancelled = false
        var existing: Set<String> = []
        var dockerSilent = false
        var restore: VolumeRestoreFlow.Outcome? = .done
        var missingImages: [String]? = []
        var load: VolumeBackupRunner.Failure?

        func steps() -> VMRecreateFlow.Steps {
            VMRecreateFlow.Steps(
                backUp: { [self] rows, _ in
                    calls.append("backUp \(rows.map(\.name).joined(separator: ","))")
                    return summary
                },
                saveImages: { [self] refs, _ in
                    calls.append("saveImages \(refs.joined(separator: ","))")
                    return imageSave
                },
                recreate: { [self] vm, mount in
                    calls.append("recreate \(vm) \(mount)")
                    return recreate
                },
                waitReady: { [self] in
                    calls.append("waitReady")
                    return ready
                },
                readTypes: { [self] in types },
                stopReason: { [self] in
                    if changedVM { return stopReasons.isEmpty ? nil : stopReasons.removeFirst() }
                    return preStops.isEmpty ? nil : preStops.removeFirst()
                },
                isCancelled: { [self] in
                    if cancelled { return true }
                    guard let cancelAfter else { return false }
                    return calls.contains { $0.hasPrefix(cancelAfter) }
                },
                restore: { [self] v, _ in
                    calls.append("restore \(v.name)")
                    return restore
                },
                volumeExists: { [self] name in dockerSilent ? nil : existing.contains(name) },
                missingImages: { [self] refs in
                    calls.append("missingImages")
                    return missingImages
                },
                loadImages: { [self] file, _ in
                    calls.append("loadImages \(file.lastPathComponent)")
                    return load
                },
                saveJournal: { [self] j in
                    calls.append("journal \(j.phase.rawValue)")
                    guard journalWorks else { return false }
                    saved.append(j)
                    return true
                },
                dropJournal: { [self] in calls.append("dropJournal") },
                progress: { [self] step in calls.append("progress \(step)") })
        }

        var changedVM: Bool { calls.contains { $0.hasPrefix("recreate ") } }
    }

    private let folder = URL(fileURLWithPath: "/tmp/ColimaBar-work-1")
    private var journal: VMRecreateJournal {
        VMRecreateJournal(
            profile: "work", from: .init(vmType: "vz", mountType: "virtiofs"),
            to: .init(vmType: "qemu", mountType: "sshfs"), folder: "/tmp/ColimaBar-work-1", created: Date(),
            phase: .backup)
    }

    private func rows(_ names: String...) -> [VolumeRow] {
        names.map { VolumeRow(name: $0, size: 1, links: 0, project: nil, isAnonymous: false) }
    }

    private func run(
        _ f: Fake, backUp: [VolumeRow] = [], images: [String] = [], restop: Bool = false, folder: URL? = nil
    ) async -> VMRecreateFlow.Outcome {
        await VMRecreateFlow.run(
            journal, folder: folder ?? self.folder, backUp: backUp, saveImages: images, restop: restop,
            steps: f.steps())
    }

    // MARK: Happy paths

    @Test func aKeptDataDiskMakesTheRestoreAndTheLoadNoOps() async {
        let f = Fake()
        f.existing = ["a", "b"]
        f.types = ("qemu", "sshfs")
        let outcome = await run(f, backUp: rows("a", "b"), images: ["nginx:1"])
        #expect(outcome == .finished(restored: 0, kept: 2, failed: [], imagesLoaded: false))
        #expect(!f.calls.contains { $0.hasPrefix("restore ") || $0.hasPrefix("loadImages") })
        #expect(f.calls.last == "dropJournal")
        #expect(f.saved.map(\.phase) == [.backup, .recreate, .restore])
        let order = f.calls.filter { !$0.hasPrefix("progress") }
        #expect(
            order == [
                "journal backup", "backUp a,b", "saveImages nginx:1", "journal recreate", "recreate qemu sshfs",
                "journal restore", "waitReady", "missingImages", "dropJournal",
            ])
    }

    @Test func aLostDataDiskRestoresEveryVolumeAndLoadsTheImages() async {
        let f = Fake()
        f.missingImages = ["nginx:1"]
        let outcome = await run(f, backUp: rows("a", "b"), images: ["nginx:1"])
        #expect(outcome == .finished(restored: 2, kept: 0, failed: [], imagesLoaded: true))
        #expect(f.calls.contains("restore a") && f.calls.contains("restore b"))
        #expect(f.calls.contains("loadImages images.tar"))
        #expect(f.saved.last?.volumes == [.init(name: "a", file: "a-1.tar"), .init(name: "b", file: "b-1.tar")])
        #expect(f.saved.last?.imagesSHA256 == String(repeating: "cd", count: 32))
        #expect(f.saved.last?.images == ["nginx:1"])
    }

    @Test func aRunWithNoBackupSkipsTheWaitAndTheRestore() async {
        let f = Fake()
        let outcome = await run(f, folder: nil)
        #expect(outcome == .finished(restored: 0, kept: 0, failed: [], imagesLoaded: false))
        #expect(f.calls.contains("recreate qemu sshfs"))
        #expect(!f.calls.contains("waitReady"))
        #expect(f.calls.last == "dropJournal")
    }

    @Test func aStoppedVMSkipsTheWaitAndTheRestore() async {
        let f = Fake()
        let outcome = await run(f, restop: true)
        #expect(outcome == .finished(restored: 0, kept: 0, failed: [], imagesLoaded: false))
        #expect(!f.calls.contains("waitReady"))
        #expect(f.calls.last == "dropJournal")
        #expect(f.saved.map(\.phase) == [.backup, .recreate])
    }

    // MARK: Before the recreate

    @Test func aFailedVolumeStopsBeforeTheRecreate() async {
        let f = Fake()
        f.summary = .init(
            done: [.init(name: "a", file: "a-1.tar", bytes: 1)],
            failed: [.init(name: "b", reason: "No space.", removedFile: true)],
            started: true)
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(
            outcome
                == .nothingChanged(
                    "Backup failed, so nothing changed: b: No space. The backups so far are in ColimaBar-work-1."))
        #expect(!f.changedVM)
        #expect(f.calls.last == "dropJournal")
    }

    @Test func aFullDiskAndAFailedPrepareStopBeforeTheRecreate() async {
        var f = Fake()
        f.summary = .init(started: true, diskFull: true)
        var outcome = await run(f, backUp: rows("a"))
        #expect(
            outcome == .nothingChanged("Backup failed, so nothing changed: The disk of your Mac is full."))
        #expect(!f.changedVM)
        f = Fake()
        f.summary = .init(prepareFailure: "Docker did not answer.")
        outcome = await run(f, backUp: rows("a"))
        #expect(outcome == .nothingChanged("Backup failed, so nothing changed: Docker did not answer."))
        #expect(!f.changedVM)
    }

    @Test func aBackupThatCannotStartStopsBeforeTheRecreate() async {
        let f = Fake()
        f.summary = nil
        #expect(await run(f, backUp: rows("a")) == .nothingChanged("ColimaBar could not start the backup."))
        #expect(!f.changedVM)
    }

    @Test func aCancelledBackupChangesNothing() async {
        let f = Fake()
        f.summary = .init(cancelled: true, started: true)
        #expect(await run(f, backUp: rows("a")) == .cancelledBeforeChange)
        #expect(!f.changedVM)
        #expect(f.calls.last == "dropJournal")
    }

    @Test func aBackupThatStoppedBecauseTheProfileChangedIsNotAUserCancel() async {
        let f = Fake()
        f.summary = .init(cancelled: true, started: true)
        // The checks before the backup pass, then the runner stops and the profile is another one.
        f.preStops = [nil, nil, .profileChanged]
        #expect(
            await run(f, backUp: rows("a"))
                == .nothingChanged("ColimaBar stopped because you chose another profile. Nothing changed."))
        #expect(!f.changedVM)
        #expect(f.calls.last == "dropJournal")
    }

    @Test func anImageSaveThatStoppedBecauseTheVMStoppedIsNotAUserCancel() async {
        let f = Fake()
        f.imageSave = .failure(.cancel)
        f.preStops = [nil, nil, nil, .vmStopped]
        #expect(
            await run(f, backUp: rows("a"), images: ["x:1"])
                == .nothingChanged(
                    "ColimaBar stopped because the VM stopped. Nothing changed. The backups so far are in ColimaBar-work-1."
                ))
        #expect(!f.changedVM)
    }

    @Test func aCancelWinsOverAStopReason() async {
        let f = Fake()
        f.summary = .init(cancelled: true, started: true)
        f.cancelAfter = "backUp"
        f.preStops = [nil, nil, .profileChanged]
        #expect(await run(f, backUp: rows("a")) == .cancelledBeforeChange)
    }

    @Test func aCancelledImageSaveGivesCancelledBeforeChange() async {
        let f = Fake()
        f.imageSave = .failure(.cancel)
        #expect(await run(f, backUp: rows("a", "b"), images: ["x:1"]) == .cancelledBeforeChange)
        #expect(!f.changedVM)
    }

    @Test func aFailedImageSaveStopsBeforeTheRecreateAndNamesTheBackups() async {
        let f = Fake()
        f.imageSave = .failure(.diskFull)
        let outcome = await run(f, backUp: rows("a", "b"), images: ["x:1"])
        #expect(
            outcome
                == .nothingChanged(
                    "Backup failed, so nothing changed: The disk of your Mac is full. The backups so far are in ColimaBar-work-1."
                ))
        #expect(!f.changedVM)
    }

    @Test func aFailureWithNoFileInTheFolderDoesNotNameTheFolder() async {
        let f = Fake()
        f.summary = .init(failed: [.init(name: "a", reason: "No space.", removedFile: true)], started: true)
        let outcome = await run(f, backUp: rows("a"))
        #expect(outcome == .nothingChanged("Backup failed, so nothing changed: a: No space."))
    }

    // MARK: Cancel, profile switch and the journal before the recreate

    @Test(arguments: [
        "journal backup", "backUp", "saveImages",
    ])
    func aCancelInAnyGapStopsBeforeTheRecreate(after: String) async {
        let f = Fake()
        f.cancelAfter = after
        let outcome = await run(f, backUp: rows("a", "b"), images: ["x:1"])
        #expect(outcome == .cancelledBeforeChange)
        #expect(!f.changedVM)
        #expect(f.calls.last == "dropJournal")
        if after == "journal backup" { #expect(!f.calls.contains { $0.hasPrefix("backUp") }) }
        if after == "backUp" { #expect(!f.calls.contains { $0.hasPrefix("saveImages") }) }
    }

    @Test func aCancelBeforeTheLastStepWithNoImagesStopsBeforeTheRecreate() async {
        let f = Fake()
        f.cancelAfter = "backUp"
        #expect(await run(f, backUp: rows("a")) == .cancelledBeforeChange)
        #expect(!f.changedVM)
    }

    @Test func aCancelBeforeTheFlowStartsWritesNoJournal() async {
        let f = Fake()
        f.cancelled = true
        #expect(await run(f, backUp: rows("a")) == .cancelledBeforeChange)
        #expect(f.saved.isEmpty && !f.changedVM)
        #expect(!f.calls.contains { $0.hasPrefix("backUp") })
    }

    @Test func aCancelWithNoBackupStopsBeforeTheRecreate() async {
        let f = Fake()
        f.cancelled = true
        #expect(await run(f, folder: nil) == .cancelledBeforeChange)
        #expect(!f.changedVM)
    }

    @Test func aProfileSwitchBeforeTheRecreateStopsAndNamesTheReason() async {
        for position in 0..<3 {
            let f = Fake()
            f.preStops = Array(repeating: nil, count: position) + [.profileChanged]
            let outcome = await run(f, backUp: rows("a"), images: ["x:1"])
            #expect(!f.changedVM, "position \(position)")
            guard case .nothingChanged(let text) = outcome else {
                Issue.record("not nothingChanged at \(position)")
                continue
            }
            #expect(text.hasPrefix("ColimaBar stopped because you chose another profile. Nothing changed."))
        }
    }

    @Test func aJournalThatCannotBeWrittenAtTheStartStopsBeforeTheBackup() async {
        let f = Fake()
        f.journalWorks = false
        let outcome = await run(f, backUp: rows("a"))
        #expect(!f.changedVM)
        #expect(!f.calls.contains { $0.hasPrefix("backUp") })
        guard case .nothingChanged(let text) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(text.contains("could not write its journal"))
    }

    @Test func aJournalThatCannotBeWrittenBeforeTheRecreateKeepsTheVMAsItIs() async {
        let f = Fake()
        // The first write works. The write for the phase `recreate` fails.
        var writes = 0
        var steps = f.steps()
        let inner = steps.saveJournal
        steps.saveJournal = { j in
            writes += 1
            return writes == 1 ? inner(j) : false
        }
        let outcome = await VMRecreateFlow.run(
            journal, folder: folder, backUp: rows("a"), saveImages: [], restop: false, steps: steps)
        #expect(!f.changedVM)
        guard case .nothingChanged(let text) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(text.contains("could not write its journal"))
        #expect(f.calls.last == "dropJournal")
    }

    @Test func aRunWithNoBackupAlsoNeedsAJournalBeforeTheRecreate() async {
        let f = Fake()
        f.journalWorks = false
        let outcome = await run(f, folder: nil)
        #expect(!f.changedVM)
        guard case .nothingChanged = outcome else {
            Issue.record("\(outcome)")
            return
        }
    }

    // MARK: The script

    @Test func aCancelInTheScriptDialogChangesNothingAndDropsTheJournal() async {
        let f = Fake()
        f.recreate = Shell.Result(status: 2, out: "")
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(outcome == .nothingChanged("Nothing changed. The backups are in ColimaBar-work-1."))
        #expect(f.calls.last == "dropJournal")
        #expect(!f.calls.contains("waitReady"))
    }

    @Test func aFailedScriptWithTheOldTypesChangedNothing() async {
        let f = Fake()
        f.recreate = Shell.Result(status: 1, out: "")
        f.types = ("vz", "virtiofs")
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(
            outcome
                == .nothingChanged(
                    "The VM type did not change. The VM may be stopped. The backups are in ColimaBar-work-1."))
        #expect(f.calls.last == "dropJournal")
    }

    @Test func aFailedScriptWithTheNewTypesKeepsTheJournalAtRestore() async {
        let f = Fake()
        f.recreate = Shell.Result(status: 1, out: "")
        f.types = ("qemu", "sshfs")
        let outcome = await run(f, backUp: rows("a", "b"))
        guard case .restorePending(let text) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(text.contains("did not start with qemu / sshfs. The backups are in ColimaBar-work-1."))
        #expect(f.saved.last?.phase == .restore)
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aFailedScriptWithAMissingFileKeepsTheJournalAtRecreate() async {
        let f = Fake()
        f.recreate = Shell.Result(status: 1, out: "")
        f.types = nil
        let outcome = await run(f, backUp: rows("a", "b"))
        guard case .restorePending = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(f.saved.last?.phase == .recreate)
    }

    @Test func aFailedStartWithNoBackupLeavesNoJournal() async {
        let f = Fake()
        f.recreate = Shell.Result(status: 1, out: "")
        f.types = ("qemu", "sshfs")
        let outcome = await run(f, folder: nil)
        #expect(
            outcome
                == .changedWithoutBackup("The VM of profile work did not start with qemu / sshfs."))
        #expect(f.calls.last == "dropJournal")
    }

    // MARK: After the recreate

    @Test func aCancelAfterTheWaitStopsBeforeTheFirstRestore() async {
        let f = Fake()
        f.cancelAfter = "waitReady"
        let outcome = await run(f, backUp: rows("a", "b"))
        guard case .restorePending(let text) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(text.hasPrefix("ColimaBar stopped the restore."))
        #expect(!f.calls.contains { $0.hasPrefix("restore ") })
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aCancelBetweenTwoVolumesStopsTheRestore() async {
        let f = Fake()
        f.cancelAfter = "restore a"
        let outcome = await run(f, backUp: rows("a", "b"))
        guard case .restorePending = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(f.calls.contains("restore a") && !f.calls.contains("restore b"))
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aCancelBeforeTheImageLoadSkipsTheLoad() async {
        let f = Fake()
        f.missingImages = ["x:1"]
        f.cancelAfter = "missingImages"
        let outcome = await run(f, backUp: rows("a"), images: ["x:1"])
        guard case .restorePending = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(!f.calls.contains { $0.hasPrefix("loadImages") })
    }

    @Test func aCancelBeforeTheCheckOfTheImagesSkipsThem() async {
        let f = Fake()
        f.cancelAfter = "restore b"
        let outcome = await run(f, backUp: rows("a", "b"), images: ["x:1"])
        guard case .restorePending = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(!f.calls.contains("missingImages"))
    }

    @Test func aGateThatFailsKeepsTheJournalForARestore() async {
        let f = Fake()
        f.ready = false
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(
            outcome
                == .restorePending(
                    "Docker did not get ready. The backups are in ColimaBar-work-1. Click Restore Backups when the VM runs."
                ))
        #expect(!f.calls.contains { $0.hasPrefix("restore ") })
        #expect(f.saved.last?.phase == .restore)
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aPartialRestoreFailureKeepsTheJournalAndNamesTheVolume() async {
        let f = Fake()
        f.restore = .failed("No space.")
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(
            outcome == .finished(restored: 0, kept: 0, failed: ["a (No space.)", "b (No space.)"], imagesLoaded: false))
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aVolumeThatExistsIsKeptAndTheOthersAreRestored() async {
        let f = Fake()
        f.existing = ["b"]
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(outcome == .finished(restored: 1, kept: 1, failed: [], imagesLoaded: false))
    }

    @Test func aVolumeThatDockerCannotCheckIsAFailure() async {
        let f = Fake()
        f.dockerSilent = true
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(
            outcome
                == .finished(
                    restored: 0, kept: 0, failed: ["a (Docker did not answer)", "b (Docker did not answer)"],
                    imagesLoaded: false))
        #expect(!f.calls.contains { $0.hasPrefix("restore ") })
    }

    @Test func aRestoreThatCannotStartIsAFailure() async {
        let f = Fake()
        f.summary = .init(done: [.init(name: "a", file: "a-1.tar", bytes: 1)], started: true)
        f.restore = nil
        let outcome = await run(f, backUp: rows("a"))
        #expect(
            outcome
                == .finished(restored: 0, kept: 0, failed: ["a (ColimaBar could not restore it)"], imagesLoaded: false))
    }

    @Test func aVMThatStoppedBeforeTheRestoreStopsTheFlowAtTheJournal() async {
        let f = Fake()
        f.stopReasons = [.vmStopped]
        let outcome = await run(f, backUp: rows("a", "b"))
        #expect(
            outcome
                == .restorePending(
                    "ColimaBar stopped the restore because the VM stopped. The backups are in ColimaBar-work-1. Click Restore Backups to go on."
                ))
        #expect(!f.calls.contains { $0.hasPrefix("restore ") })
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aChangedProfileStopsTheFlowToo() async {
        let f = Fake()
        f.stopReasons = [nil, .profileChanged]
        f.restore = .done
        let outcome = await run(f, backUp: rows("a", "b"))
        guard case .restorePending(let text) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(text.contains("because you chose another profile"))
        #expect(f.calls.contains("restore a") && !f.calls.contains("restore b"))
    }

    @Test func aCancelledRestoreStopsTheFlowAndKeepsTheJournal() async {
        let f = Fake()
        f.restore = .cancelled(.nothing)
        let outcome = await run(f, backUp: rows("a", "b"))
        guard case .restorePending(let text) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(text.hasPrefix("ColimaBar stopped the restore."))
        #expect(f.calls.filter { $0.hasPrefix("restore ") } == ["restore a"])
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aFailedImageLoadIsAFailureAndKeepsTheJournal() async {
        let f = Fake()
        f.missingImages = ["x:1"]
        f.load = .text("The image file changed. ColimaBar does not load it.")
        let outcome = await run(f, images: ["x:1"])
        #expect(
            outcome
                == .finished(
                    restored: 0, kept: 0, failed: ["images (The image file changed. ColimaBar does not load it.)"],
                    imagesLoaded: false))
        #expect(f.calls.last != "dropJournal")
    }

    @Test func aCancelledImageLoadStopsTheFlow() async {
        let f = Fake()
        f.missingImages = ["x:1"]
        f.load = .cancel
        guard case .restorePending = await run(f, images: ["x:1"]) else {
            Issue.record("not pending")
            return
        }
    }

    @Test func imagesThatDockerCannotCheckAreAFailure() async {
        let f = Fake()
        f.missingImages = nil
        let outcome = await run(f, images: ["x:1"])
        #expect(
            outcome == .finished(restored: 0, kept: 0, failed: ["images (Docker did not answer)"], imagesLoaded: false))
    }

    // MARK: Resume

    private var pending: VMRecreateJournal {
        var j = journal
        j.phase = .restore
        j.volumes = [.init(name: "a", file: "a-1.tar"), .init(name: "b", file: "b-1.tar")]
        j.imagesFile = "images.tar"
        j.imagesSHA256 = String(repeating: "cd", count: 32)
        j.images = ["x:1"]
        return j
    }

    @Test func aResumeRestoresOnlyWhatIsMissingAndASecondRunRestoresNothing() async {
        let f = Fake()
        f.existing = ["b"]
        f.missingImages = ["x:1"]
        let first = await VMRecreateFlow.resume(pending, folder: folder, steps: f.steps())
        #expect(first == .finished(restored: 1, kept: 1, failed: [], imagesLoaded: true))
        #expect(f.calls.filter { $0.hasPrefix("restore ") } == ["restore a"])
        #expect(f.calls.last == "dropJournal")
        let g = Fake()
        g.existing = ["a", "b"]
        g.missingImages = []
        let second = await VMRecreateFlow.resume(pending, folder: folder, steps: g.steps())
        #expect(second == .finished(restored: 0, kept: 2, failed: [], imagesLoaded: false))
        #expect(!g.calls.contains { $0.hasPrefix("restore ") || $0.hasPrefix("loadImages") })
        #expect(!g.calls.contains { $0.hasPrefix("recreate") || $0.hasPrefix("backUp") })
    }
}
