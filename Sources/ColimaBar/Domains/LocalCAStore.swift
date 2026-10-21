import Darwin
import Foundation

/// The files of the local certificate authority, in one private folder:
/// `ca.der` (0600), `ca.pem` (0644, for `NODE_EXTRA_CA_CERTS`) and
/// `ca-key.raw` (0600, the 97 bytes `04 || X || Y || D`). The folder is 0700
/// and not in Time Machine backups. `save` builds a new set in `domains.new`
/// and swaps it in.
enum LocalCAStore {
    static var dir: String { Paths.domainsDir }
    static let derName = "ca.der"
    static let pemName = "ca.pem"
    static let keyName = "ca-key.raw"

    static func pemPath(dir: String = dir) -> String { "\(dir)/\(pemName)" }

    /// The saved CA, or nil if a file is missing or invalid, a path is a
    /// symlink, the owner is not this user, or the key or the certificate
    /// has a mode other than 0600.
    static func load(dir: String = dir) -> LocalCA? {
        settleLeftover(dir)
        guard isPrivateFolder(dir), isPrivateFile("\(dir)/\(keyName)", mode: 0o600),
            isPrivateFile("\(dir)/\(derName)", mode: 0o600),
            let der = FileManager.default.contents(atPath: "\(dir)/\(derName)"),
            let key = FileManager.default.contents(atPath: "\(dir)/\(keyName)")
        else { return nil }
        return try? LocalCA.restore(certificateDER: [UInt8](der), keyX963: [UInt8](key))
    }

    /// The folder where `save` builds the next set of files.
    private static func stagingPath(_ dir: String) -> String { dir + ".new" }

    /// Where `replace` parks the old folder while the new one moves in.
    private static func oldPath(_ dir: String) -> String { dir + ".old" }

    /// Handles a `dir.old` that a crash left. If `dir` is gone, the crash came
    /// between the two renames: the old folder comes back. Else it goes.
    private static func settleLeftover(_ dir: String) {
        if TestProcess.isRunning, dir == Paths.domainsDir { return }
        let old = oldPath(dir)
        var info = stat()
        guard lstat(old, &info) == 0 else { return }
        if lstat(dir, &info) != 0, rename(old, dir) == 0 { return }
        try? FileManager.default.removeItem(atPath: old)
    }

    /// Writes the three files into a staging folder next to `dir`, then
    /// swaps the folders with one rename. A crash leaves the old set or the
    /// new set, never a certificate with the key of another CA.
    static func save(_ ca: LocalCA, dir: String = dir) throws {
        // A test process never writes the folder of the user.
        if TestProcess.isRunning, dir == Paths.domainsDir { throw POSIXError(.EPERM) }
        let fm = FileManager.default
        let staging = stagingPath(dir)
        settleLeftover(dir)
        try fm.createDirectory(
            atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: staging)
        try fm.createDirectory(
            atPath: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard chmod(staging, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try write(Data(try ca.keyX963()), to: "\(staging)/\(keyName)", mode: 0o600)
            try write(Data(ca.der), to: "\(staging)/\(derName)", mode: 0o600)
            try write(Data(X509Builder.pem(ca.der).utf8), to: "\(staging)/\(pemName)", mode: 0o644)
            var url = URL(fileURLWithPath: staging)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            try replace(dir, with: staging)
        } catch {
            try? fm.removeItem(atPath: staging)
            throw error
        }
    }

    /// Puts the staging folder in place of `dir`. A folder or a file that is
    /// there goes away, and a symlink is never followed. If the swap is not
    /// possible, two renames do it: `dir` goes to `dir.old`, then the staging
    /// folder comes in. If the second rename fails, the first one is undone,
    /// so one copy of the files always exists.
    private static func replace(_ dir: String, with staging: String) throws {
        let fm = FileManager.default
        var info = stat()
        if lstat(dir, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFDIR, renamex_np(staging, dir, UInt32(RENAME_SWAP)) == 0 {
                try? fm.removeItem(atPath: staging)
                return
            }
            let old = oldPath(dir)
            try? fm.removeItem(atPath: old)
            guard rename(dir, old) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard rename(staging, dir) == 0 else {
                let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                _ = rename(old, dir)
                throw failure
            }
            try? fm.removeItem(atPath: old)
            return
        }
        guard rename(staging, dir) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Deletes the key first, so that the CA can never sign again, then the folder.
    static func remove(dir: String = dir) {
        if TestProcess.isRunning, dir == Paths.domainsDir { return }
        unlink("\(dir)/\(keyName)")
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: stagingPath(dir))
        try? FileManager.default.removeItem(atPath: oldPath(dir))
    }

    private static func write(_ data: Data, to path: String, mode: mode_t) throws {
        let writer = try PrivateFileWriter(destination: path, replace: true)
        try writer.write(data)
        try writer.commit()
        guard chmod(path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func isPrivateFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0
    }

    private static func isPrivateFile(_ path: String, mode: mode_t) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
            && info.st_mode & 0o777 == mode
    }
}
