import Foundation

/// How this copy of ColimaBar was installed, and so how it can update.
enum InstallSource: Equatable, Sendable {
    /// ColimaBar replaces its own bundle at this URL.
    case selfUpdate(URL)
    /// Homebrew owns the copy. ColimaBar shows the `brew` command.
    case homebrew
    /// ColimaBar opens the release page.
    case linkOnly(Reason)

    enum Reason: Equatable, Sendable {
        case debugRun
        case devBuild
        /// Not in /Applications or ~/Applications: a disk image, Downloads
        /// or an app translocation path.
        case notInstalled
        case readOnly
        /// The folder or the bundle is not writable for this user, another
        /// user owns the bundle, or the bundle is a symlink.
        case notWritable

        /// The reason as a clause for a hint or an alert.
        var text: String {
            switch self {
            case .debugRun: "this is a debug run"
            case .devBuild: "this is a development build"
            case .notInstalled: "this copy does not run from /Applications or ~/Applications"
            case .readOnly: "the disk of this copy is read-only"
            case .notWritable: "ColimaBar cannot change its own folder"
            }
        }
    }

    /// The file system questions of `detect`, so tests need no real files.
    struct Disk: Sendable {
        /// The link targets (resolved paths) of `*/ColimaBar.app` in the
        /// Caskroom folder, or an empty list.
        var caskroomLinks: @Sendable (_ caskroom: String) -> [String]
        var exists: @Sendable (_ path: String) -> Bool
        var isWritable: @Sendable (_ path: String) -> Bool
        var isReadOnlyVolume: @Sendable (_ path: String) -> Bool
        var isSymlink: @Sendable (_ path: String) -> Bool
        var ownerUID: @Sendable (_ path: String) -> UInt32?
        var uid: UInt32

        static let live = Disk(
            caskroomLinks: { caskroom in
                let fm = FileManager.default
                return ((try? fm.contentsOfDirectory(atPath: caskroom)) ?? []).compactMap {
                    try? fm.destinationOfSymbolicLink(atPath: "\(caskroom)/\($0)/ColimaBar.app")
                }
            },
            exists: { FileManager.default.fileExists(atPath: $0) },
            isWritable: { FileManager.default.isWritableFile(atPath: $0) },
            isReadOnlyVolume: { path in
                var s = statfs()
                return statfs(path, &s) == 0 && (s.f_flags & UInt32(MNT_RDONLY)) != 0
            },
            isSymlink: { path in
                (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
            },
            ownerUID: { path in
                (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountID] as? UInt32
            },
            uid: getuid())
    }

    static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// The first rule that fits decides:
    /// 1. a debug run
    /// 2. a version that is not exactly X.Y.Z (a development build)
    /// 3. Homebrew: its Caskroom link points to this bundle, or the Caskroom
    ///    folder exists and this is /Applications/ColimaBar.app
    /// 4. a copy that is not installed (disk image, Downloads, translocated)
    /// 5. a read-only volume
    /// 6. a folder or bundle that this user cannot write, a bundle that
    ///    another user owns, or a bundle that is a symlink
    nonisolated static func detect(bundlePath: String, version: String, isDebug: Bool, disk: Disk) -> InstallSource {
        if isDebug { return .linkOnly(.debugRun) }
        if !ReleaseLink.isReleaseTag(version) || version.hasPrefix("v") { return .linkOnly(.devBuild) }
        for prefix in homebrewPrefixes {
            let caskroom = "\(prefix)/Caskroom/colima-bar"
            if disk.caskroomLinks(caskroom).contains(bundlePath)
                || (disk.exists(caskroom) && bundlePath == "/Applications/ColimaBar.app")
            {
                return .homebrew
            }
        }
        if !LoginItem.isInstalled(bundlePath) { return .linkOnly(.notInstalled) }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        if disk.isReadOnlyVolume(parent) { return .linkOnly(.readOnly) }
        if disk.isSymlink(bundlePath) || !disk.isWritable(parent) || !disk.isWritable(bundlePath)
            || disk.ownerUID(bundlePath).map({ $0 != disk.uid }) == true
        {
            return .linkOnly(.notWritable)
        }
        return .selfUpdate(URL(fileURLWithPath: bundlePath))
    }
}
