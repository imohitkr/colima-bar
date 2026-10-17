import Darwin
import Foundation
import os

/// Replaces the installed bundle with the verified one by rename only. It
/// never writes into the running bundle: the old binary keeps its inode, and
/// the swap is one step that cannot leave half an app.
enum BundleSwap {
    private static let log = Logger(category: "update")

    /// A failed file operation. `code` is the errno value.
    struct FileError: Error, Equatable {
        let code: Int32
    }

    /// The file operations, as closures so tests can fail each step.
    struct FileOps: Sendable {
        /// Swaps two paths in one step (`renamex_np` with `RENAME_SWAP`).
        var swap: @Sendable (_ a: String, _ b: String) throws -> Void
        var rename: @Sendable (_ from: String, _ to: String) throws -> Void
        /// Copies a bundle with `ditto`.
        var copy: @Sendable (_ from: String, _ to: String) throws -> Void
        var remove: @Sendable (_ path: String) -> Void
        var exists: @Sendable (_ path: String) -> Bool
        var makeFolder: @Sendable (_ path: String) throws -> Void
        /// The signature and identifier check of a bundle.
        var signatureIsValid: @Sendable (_ path: String) -> Bool
        var onDiskVersion: @Sendable (_ bundle: String) -> String?

        static let live = FileOps(
            swap: { a, b in
                if renamex_np(a, b, UInt32(RENAME_SWAP)) != 0 { throw FileError(code: errno) }
            },
            rename: { from, to in
                if Darwin.rename(from, to) != 0 { throw FileError(code: errno) }
            },
            copy: { from, to in
                let r = Shell.runSync("/usr/bin/ditto", [from, to], includeStderr: true)
                if !r.ok {
                    BundleSwap.log.error(
                        "ditto failed with status \(r.status): \(r.out.prefix(1000), privacy: .public)")
                    throw FileError(code: EIO)
                }
            },
            remove: { path in
                do { try FileManager.default.removeItem(atPath: path) } catch let e as CocoaError
                    where e.code == .fileNoSuchFile
                {
                    // Already gone.
                } catch {
                    BundleSwap.log.error(
                        "cannot remove \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            },
            exists: { FileManager.default.fileExists(atPath: $0) },
            makeFolder: { path in
                try FileManager.default.createDirectory(
                    atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            },
            signatureIsValid: { path in
                Shell.runSync("/usr/bin/codesign", Array(UpdateVerifier.codesignArguments(path).dropFirst())).ok
            },
            onDiskVersion: { AppDelegate.onDiskVersion(of: URL(fileURLWithPath: $0)) })
    }

    enum Plan: Equatable {
        /// The unpacked copy is on the volume of the target: swap it in place.
        case direct
        /// Copy to this path beside the target first, then swap.
        case copy(to: String)
    }

    /// The hidden path beside the target for a copy from another volume.
    static func stagePath(target: String) -> String {
        "\((target as NSString).deletingLastPathComponent)/.ColimaBar-update.app"
    }

    /// The hidden path beside the target where an old bundle waits when it
    /// cannot go to `previous`. The name starts with a dot, so
    /// `LoginItem.isInstalled` never accepts it.
    static func sidePath(target: String) -> String {
        "\((target as NSString).deletingLastPathComponent)/.ColimaBar-old.app"
    }

    /// After a failed `commit` (or a cancel or a time-out after `prepare`):
    /// removes the staged copy from the folder of the target. A staged path
    /// that is the unpacked copy lives in the work folder, so it stays. After
    /// a `rollbackFailed` error the staged path can hold the old bundle, so
    /// it stays too. Returns true if it removed the path.
    @discardableResult
    static func discard(staged: String, unpacked: String, after error: any Error, ops: FileOps) -> Bool {
        guard staged != unpacked else { return false }
        if case UpdateError.rollbackFailed = error { return false }
        ops.remove(staged)
        return true
    }

    static func plan(target: String, unpacked: String, sameVolume: Bool) -> Plan {
        sameVolume ? .direct : .copy(to: stagePath(target: target))
    }

    /// True if both paths are on one volume (the same `st_dev`). The target
    /// is checked through its folder.
    static func onSameVolume(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        let parent = (b as NSString).deletingLastPathComponent
        guard stat(a, &x) == 0, stat(parent, &y) == 0 else { return false }
        return x.st_dev == y.st_dev
    }

    /// Step 1, which can take time: gets the verified copy ready beside the
    /// target. Returns the path that the swap uses. A copy to another volume
    /// is signed-checked again.
    static func prepare(target: String, unpacked: String, sameVolume: Bool, ops: FileOps) throws -> String {
        switch plan(target: target, unpacked: unpacked, sameVolume: sameVolume) {
        case .direct:
            return unpacked
        case .copy(let stage):
            ops.remove(stage)
            do { try ops.copy(unpacked, stage) } catch {
                ops.remove(stage)
                throw UpdateError.swapFailed("the copy failed")
            }
            guard ops.signatureIsValid(stage) else {
                ops.remove(stage)
                throw UpdateError.signatureInvalid
            }
            return stage
        }
    }

    /// Step 2, rename only, so it is quick: swaps `staged` and `target`,
    /// checks the version on disk, and moves the old bundle to `previous`.
    /// If the check fails, it swaps back, so the old bundle stays at `target`.
    /// A file system without swap support gets two renames instead.
    /// If the old bundle cannot go back, it throws `rollbackFailed` with the
    /// path of the old bundle, and the caller must keep that path.
    /// After an error other than `rollbackFailed`, `staged` holds the new
    /// bundle and `target` the old one; the caller removes `staged`.
    static func commit(
        target: String, staged: String, previous: String, expectedVersion: String, ops: FileOps
    ) throws {
        var useTwoRenames = false
        do { try ops.swap(staged, target) } catch let e as FileError {
            switch e.code {
            case ENOTSUP, EINVAL: useTwoRenames = true
            case EPERM, EACCES: throw UpdateError.macOSBlocked
            default: throw UpdateError.swapFailed("error \(e.code)")
            }
        }
        // The old bundle is at `old`: the staged path after a swap, or a
        // side path after two renames.
        var old = staged
        if useTwoRenames {
            old = sidePath(target: target)
            ops.remove(old)
            do { try ops.rename(target, old) } catch let e as FileError {
                throw e.code == EPERM || e.code == EACCES
                    ? UpdateError.macOSBlocked : UpdateError.swapFailed("error \(e.code)")
            }
            do { try ops.rename(staged, target) } catch {
                // Put the old bundle back.
                do { try ops.rename(old, target) } catch {
                    log.error(
                        "the old bundle did not go back to \(target, privacy: .public); it is at \(old, privacy: .public)"
                    )
                    throw UpdateError.rollbackFailed(old)
                }
                throw UpdateError.swapFailed("the new bundle could not be moved in")
            }
        }
        guard ops.onDiskVersion(target) == expectedVersion else {
            do {
                if useTwoRenames {
                    try ops.rename(target, staged)
                    try ops.rename(old, target)
                } else {
                    try ops.swap(staged, target)
                }
            } catch {
                log.error(
                    "rollback failed (\(String(describing: error), privacy: .public)); the old bundle is at \(old, privacy: .public)"
                )
                throw UpdateError.rollbackFailed(old)
            }
            throw UpdateError.bundleInvalid("the version on disk is not \(expectedVersion)")
        }
        retire(old: old, target: target, previous: previous, ops: ops)
    }

    /// Moves the old bundle out of the way for a way back. The update itself
    /// worked, so nothing here throws. A rename to another volume fails
    /// (EXDEV), so it then copies. If that fails too, the old bundle gets a
    /// hidden name beside the target, or is removed. It never stays at a name
    /// that a launch would accept as a newer copy: `LoginItem.isInstalled`
    /// rejects names that start with a dot.
    private static func retire(old: String, target: String, previous: String, ops: FileOps) {
        let folder = (previous as NSString).deletingLastPathComponent
        do {
            try ops.makeFolder(folder)
            ops.remove(previous)
            try ops.rename(old, previous)
            return
        } catch {
            log.notice("rename to previous failed (\(String(describing: error), privacy: .public)); copying")
        }
        do {
            ops.remove(previous)
            try ops.copy(old, previous)
            ops.remove(old)
            return
        } catch {
            log.error("copy to previous failed: \(String(describing: error), privacy: .public)")
            ops.remove(previous)
        }
        let side = sidePath(target: target)
        if old == side { return }
        ops.remove(side)
        do { try ops.rename(old, side) } catch {
            log.error("cannot hide the old bundle: \(String(describing: error), privacy: .public); removing it")
            ops.remove(old)
        }
    }

    /// Both steps, for a caller that does not need to wait between them.
    static func perform(
        target: String, unpacked: String, previous: String, expectedVersion: String, sameVolume: Bool, ops: FileOps
    ) throws {
        let staged = try prepare(target: target, unpacked: unpacked, sameVolume: sameVolume, ops: ops)
        try commit(target: target, staged: staged, previous: previous, expectedVersion: expectedVersion, ops: ops)
    }
}
