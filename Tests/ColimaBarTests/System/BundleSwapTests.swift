import Foundation
import Testing

@testable import ColimaBar

/// These tests use bundles in a temporary folder with a fake `FileOps`
/// or the real one. They never touch /Applications.
@Suite struct BundleSwapTests {
    /// A folder with `target` (old version), `unpacked` (new version) and `previous`.
    private struct Layout: @unchecked Sendable {
        let tmp = try! TempFolder()
        var root: String { tmp.path }
        var target: String { "\(root)/apps/ColimaBar.app" }
        var unpacked: String { "\(root)/update/unpacked/ColimaBar.app" }
        var previous: String { "\(root)/update/previous/ColimaBar.app" }

        func bundle(_ path: String, version: String) throws {
            try FileManager.default.createDirectory(atPath: "\(path)/Contents", withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: "\(path)/Contents/Info.plist"))
        }

        func make() throws {
            try bundle(target, version: "0.9.0")
            try bundle(unpacked, version: "0.9.1")
        }

        func version(_ path: String) -> String? { AppDelegate.onDiskVersion(of: URL(fileURLWithPath: path)) }
    }

    /// Fake operations that keep a call log.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    /// Runs `perform` on its own thread: the live copy waits for `ditto`.
    private func perform(
        _ l: Layout, sameVolume: Bool = true, ops: BundleSwap.FileOps = .live, version: String = "0.9.1"
    ) async throws {
        try await onOwnThread {
            Result {
                try BundleSwap.perform(
                    target: l.target, unpacked: l.unpacked, previous: l.previous, expectedVersion: version,
                    sameVolume: sameVolume, ops: ops)
            }
        }.get()
    }

    // MARK: plan

    @Test func aSameVolumeUnpackedCopySwapsDirectly() {
        #expect(
            BundleSwap.plan(target: "/Applications/ColimaBar.app", unpacked: "/x/ColimaBar.app", sameVolume: true)
                == .direct)
    }

    @Test func anotherVolumeCopiesBesideTheTargetFirst() {
        #expect(
            BundleSwap.plan(target: "/Applications/ColimaBar.app", unpacked: "/x/ColimaBar.app", sameVolume: false)
                == .copy(to: "/Applications/.ColimaBar-update.app"))
    }

    @Test func foldersOfOneTempFolderAreOnOneVolume() throws {
        let l = Layout()
        try l.make()
        #expect(BundleSwap.onSameVolume(l.unpacked, l.target))
        #expect(!BundleSwap.onSameVolume("/nonexistent/x", l.target))
    }

    // MARK: swap with the real file operations

    @Test func swapsTheNewBundleInAndKeepsTheOldOne() async throws {
        let l = Layout()
        try l.make()
        try await perform(l)
        #expect(l.version(l.target) == "0.9.1")
        #expect(l.version(l.previous) == "0.9.0")
        #expect(!FileManager.default.fileExists(atPath: l.unpacked))
    }

    @Test func swapsBackWhenTheVersionOnDiskIsWrong() async throws {
        let l = Layout()
        try l.make()
        await #expect(throws: UpdateError.self) { try await perform(l, version: "0.9.5") }
        #expect(l.version(l.target) == "0.9.0")
        #expect(l.version(l.unpacked) == "0.9.1")
        #expect(!FileManager.default.fileExists(atPath: l.previous))
    }

    @Test func aMissingTargetFailsWithoutChange() async throws {
        let l = Layout()
        try l.bundle(l.unpacked, version: "0.9.1")
        await #expect(throws: UpdateError.self) { try await perform(l) }
        #expect(l.version(l.unpacked) == "0.9.1")
    }

    // MARK: swap with fake operations

    /// Real renames, with a failure at a chosen step.
    private func ops(
        calls: Calls = Calls(), swapError: Int32? = nil, failRename: String? = nil, failCopy: Bool = false,
        signatureValid: Bool = true, failSecondRename: Bool = false, failRenameNumbers: Set<Int> = [],
        firstRenameError: Int32? = nil, failCopyTo: String? = nil, secondSwapError: Int32? = nil
    ) -> BundleSwap.FileOps {
        var o = BundleSwap.FileOps.live
        let live = BundleSwap.FileOps.live
        let renameCount = Counter()
        let swapCount = Counter()
        o.swap = { a, b in
            calls.add("swap")
            swapCount.add()
            if let secondSwapError, swapCount.value == 2 { throw BundleSwap.FileError(code: secondSwapError) }
            if let swapError { throw BundleSwap.FileError(code: swapError) }
            try live.swap(a, b)
        }
        o.rename = { from, to in
            renameCount.add()
            calls.add(
                "rename \((from as NSString).lastPathComponent) -> \(((to as NSString).deletingLastPathComponent as NSString).lastPathComponent)"
            )
            if failSecondRename, renameCount.value == 2 { throw BundleSwap.FileError(code: EIO) }
            if failRenameNumbers.contains(renameCount.value) { throw BundleSwap.FileError(code: EIO) }
            if let firstRenameError, renameCount.value == 1 { throw BundleSwap.FileError(code: firstRenameError) }
            if let failRename, to.contains(failRename) { throw BundleSwap.FileError(code: EXDEV) }
            try live.rename(from, to)
        }
        o.copy = { from, to in
            calls.add("copy")
            if failCopy { throw BundleSwap.FileError(code: EIO) }
            if let failCopyTo, to.contains(failCopyTo) { throw BundleSwap.FileError(code: EIO) }
            try live.copy(from, to)
        }
        o.signatureIsValid = { _ in signatureValid }
        return o
    }

    @Test func fallsBackToTwoRenamesWhenTheFileSystemCannotSwap() async throws {
        let l = Layout()
        try l.make()
        let calls = Calls()
        try await perform(l, ops: ops(calls: calls, swapError: ENOTSUP))
        #expect(l.version(l.target) == "0.9.1")
        #expect(l.version(l.previous) == "0.9.0")
    }

    @Test func putsTheOldBundleBackWhenTheSecondRenameFails() async throws {
        let l = Layout()
        try l.make()
        await #expect(throws: UpdateError.self) {
            try await perform(l, ops: ops(swapError: ENOTSUP, failSecondRename: true))
        }
        #expect(l.version(l.target) == "0.9.0")
        #expect(l.version(l.unpacked) == "0.9.1")
    }

    @Test func twoRenamesRollBackWhenTheVersionIsWrong() async throws {
        let l = Layout()
        try l.make()
        await #expect(throws: UpdateError.self) { try await perform(l, ops: ops(swapError: ENOTSUP), version: "0.9.5") }
        #expect(l.version(l.target) == "0.9.0")
        #expect(l.version(l.unpacked) == "0.9.1")
    }

    @Test func aPermissionErrorMeansMacOSBlockedTheChange() async throws {
        let l = Layout()
        try l.make()
        for code in [EPERM, EACCES] {
            await #expect(throws: UpdateError.macOSBlocked) { try await perform(l, ops: ops(swapError: code)) }
        }
        #expect(l.version(l.target) == "0.9.0")
    }

    @Test func anotherSwapErrorFailsWithoutChange() async throws {
        let l = Layout()
        try l.make()
        await #expect(throws: UpdateError.self) { try await perform(l, ops: ops(swapError: EIO)) }
        #expect(l.version(l.target) == "0.9.0")
    }

    @Test func aFailedMoveToPreviousStillCountsAsInstalled() async throws {
        let l = Layout()
        try l.make()
        try await perform(l, ops: ops(failRename: "previous"))
        #expect(l.version(l.target) == "0.9.1")
    }

    // MARK: another volume

    @Test func copiesToTheStagePathAndSwapsItIn() async throws {
        let l = Layout()
        try l.make()
        let calls = Calls()
        try await perform(l, sameVolume: false, ops: ops(calls: calls))
        #expect(calls.all.contains("copy"))
        #expect(l.version(l.target) == "0.9.1")
        #expect(l.version(l.previous) == "0.9.0")
        // The unpacked copy stays, and nothing is left beside the target.
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.stagePath(target: l.target)))
    }

    @Test func aFailedCopyLeavesTheTargetAndNoStageFolder() async throws {
        let l = Layout()
        try l.make()
        let calls = Calls()
        await #expect(throws: UpdateError.self) {
            try await perform(l, sameVolume: false, ops: ops(calls: calls, failCopy: true))
        }
        #expect(!calls.all.contains("swap"))
        #expect(l.version(l.target) == "0.9.0")
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.stagePath(target: l.target)))
    }

    @Test func aCopyWithABadSignatureIsRemovedBeforeTheSwap() async throws {
        let l = Layout()
        try l.make()
        let calls = Calls()
        await #expect(throws: UpdateError.signatureInvalid) {
            try await perform(l, sameVolume: false, ops: ops(calls: calls, signatureValid: false))
        }
        #expect(!calls.all.contains("swap"))
        #expect(l.version(l.target) == "0.9.0")
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.stagePath(target: l.target)))
    }

    @Test func prepareDoesNotChangeTheTarget() async throws {
        let l = Layout()
        try l.make()
        let o = ops()
        let staged = try await onOwnThread {
            Result { try BundleSwap.prepare(target: l.target, unpacked: l.unpacked, sameVolume: false, ops: o) }
        }.get()
        #expect(staged == BundleSwap.stagePath(target: l.target))
        #expect(l.version(l.target) == "0.9.0")
        #expect(l.version(staged) == "0.9.1")
    }

    // MARK: errors of the two-rename path

    @Test func fallsBackToTwoRenamesOnEINVAL() async throws {
        let l = Layout()
        try l.make()
        try await perform(l, ops: ops(swapError: EINVAL))
        #expect(l.version(l.target) == "0.9.1")
        #expect(l.version(l.previous) == "0.9.0")
    }

    @Test func aPermissionErrorAtTheFirstRenameMeansMacOSBlocked() async throws {
        let l = Layout()
        try l.make()
        for code in [EPERM, EACCES] {
            await #expect(throws: UpdateError.macOSBlocked) {
                try await perform(l, ops: ops(swapError: ENOTSUP, firstRenameError: code))
            }
        }
        #expect(l.version(l.target) == "0.9.0")
        #expect(l.version(l.unpacked) == "0.9.1")
    }

    // MARK: a rollback that fails

    @Test func aFailedSwapBackReportsWhereTheOldBundleIs() async throws {
        let l = Layout()
        try l.make()
        // The version is wrong, so the update swaps back, and that fails.
        await #expect(throws: UpdateError.rollbackFailed(l.unpacked)) {
            try await perform(l, ops: ops(secondSwapError: EIO), version: "0.9.5")
        }
        #expect(l.version(l.unpacked) == "0.9.0")
    }

    @Test func aFailedRenameBackReportsWhereTheOldBundleIs() async throws {
        let l = Layout()
        try l.make()
        let side = BundleSwap.sidePath(target: l.target)
        // Renames: 1 target to side, 2 staged to target, 3 target back to
        // staged, 4 side back to target. The fourth fails.
        await #expect(throws: UpdateError.rollbackFailed(side)) {
            try await perform(l, ops: ops(swapError: ENOTSUP, failRenameNumbers: [4]), version: "0.9.5")
        }
        #expect(l.version(side) == "0.9.0")
    }

    @Test func aSecondRenameAndItsRenameBackThatFailReportTheOldBundle() async throws {
        let l = Layout()
        try l.make()
        let side = BundleSwap.sidePath(target: l.target)
        await #expect(throws: UpdateError.rollbackFailed(side)) {
            try await perform(l, ops: ops(swapError: ENOTSUP, failRenameNumbers: [2, 3]))
        }
        #expect(l.version(side) == "0.9.0")
    }

    // MARK: no staged copy stays beside the target

    private func staged(_ l: Layout, ops: BundleSwap.FileOps) async throws -> String {
        try await onOwnThread {
            Result { try BundleSwap.prepare(target: l.target, unpacked: l.unpacked, sameVolume: false, ops: ops) }
        }.get()
    }

    private func commit(_ l: Layout, staged: String, ops: BundleSwap.FileOps, version: String = "0.9.1") async throws {
        try await onOwnThread {
            Result {
                try BundleSwap.commit(
                    target: l.target, staged: staged, previous: l.previous, expectedVersion: version, ops: ops)
            }
        }.get()
    }

    @Test func aWrongVersionAfterACopyLeavesNoStagedBundleBesideTheTarget() async throws {
        let l = Layout()
        try l.make()
        let stage = try await staged(l, ops: ops())
        await #expect(throws: UpdateError.self) { try await commit(l, staged: stage, ops: ops(), version: "0.9.5") }
        // After the swap back, the stage holds the new bundle.
        #expect(l.version(stage) == "0.9.1")
        #expect(BundleSwap.discard(staged: stage, unpacked: l.unpacked, after: UpdateError.macOSBlocked, ops: .live))
        #expect(!FileManager.default.fileExists(atPath: stage))
        #expect(l.version(l.target) == "0.9.0")
    }

    @Test func aCancelAfterTheCopyRemovesTheStagedBundle() async throws {
        let l = Layout()
        try l.make()
        let stage = try await staged(l, ops: ops())
        #expect(FileManager.default.fileExists(atPath: stage))
        BundleSwap.discard(staged: stage, unpacked: l.unpacked, after: CancellationError(), ops: .live)
        #expect(!FileManager.default.fileExists(atPath: stage))
        #expect(l.version(l.target) == "0.9.0")
    }

    @Test func aBlockedSwapAfterTheCopyLeavesNothingToDiscardButTheStage() async throws {
        let l = Layout()
        try l.make()
        let stage = try await staged(l, ops: ops())
        await #expect(throws: UpdateError.macOSBlocked) {
            try await commit(l, staged: stage, ops: ops(swapError: EPERM))
        }
        BundleSwap.discard(staged: stage, unpacked: l.unpacked, after: UpdateError.macOSBlocked, ops: .live)
        #expect(!FileManager.default.fileExists(atPath: stage))
        #expect(l.version(l.target) == "0.9.0")
    }

    @Test func theUnpackedCopyIsNotDiscardedWhenItIsTheStagedPath() throws {
        let l = Layout()
        try l.make()
        #expect(!BundleSwap.discard(staged: l.unpacked, unpacked: l.unpacked, after: CancellationError(), ops: .live))
        #expect(l.version(l.unpacked) == "0.9.1")
    }

    @Test func theStagedPathStaysAfterAFailedRollback() throws {
        // After a failed rollback the staged path can hold the old bundle.
        let l = Layout()
        try l.make()
        let stage = BundleSwap.stagePath(target: l.target)
        try l.bundle(stage, version: "0.9.0")
        #expect(
            !BundleSwap.discard(
                staged: stage, unpacked: l.unpacked, after: UpdateError.rollbackFailed(stage), ops: .live))
        #expect(l.version(stage) == "0.9.0")
    }

    // MARK: the old bundle on another volume

    @Test func theOldBundleLeavesTheApplicationsFolderWhenTheRenameToPreviousFails() async throws {
        let l = Layout()
        try l.make()
        // A rename across volumes fails with EXDEV, so the old bundle is copied.
        try await perform(l, sameVolume: false, ops: ops(failRename: "previous"))
        #expect(l.version(l.target) == "0.9.1")
        #expect(l.version(l.previous) == "0.9.0")
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.stagePath(target: l.target)))
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.sidePath(target: l.target)))
    }

    @Test func theOldBundleGetsAHiddenNameWhenItCannotGoToPrevious() async throws {
        let l = Layout()
        try l.make()
        let o = ops(failRename: "previous", failCopyTo: "previous")
        try await perform(l, sameVolume: false, ops: o)
        #expect(l.version(l.target) == "0.9.1")
        // The old bundle is not at the stage name that a launch could accept.
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.stagePath(target: l.target)))
        #expect(l.version(BundleSwap.sidePath(target: l.target)) == "0.9.0")
        #expect(!LoginItem.isInstalled(BundleSwap.sidePath(target: "/Applications/ColimaBar.app")))
    }

    @Test func theOldBundleIsRemovedWhenNoMoveWorks() async throws {
        let l = Layout()
        try l.make()
        let o = ops(failRename: "ColimaBar", failCopyTo: "previous")
        // Every rename of the old bundle fails with EXDEV, so nothing is left.
        try await perform(l, sameVolume: false, ops: o)
        #expect(l.version(l.target) == "0.9.1")
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.stagePath(target: l.target)))
        #expect(!FileManager.default.fileExists(atPath: BundleSwap.sidePath(target: l.target)))
    }
}
