import Darwin
import Foundation

/// The files of the local certificate authority, in one private folder:
/// `ca.der` (0600), `ca.pem` (0644, for `NODE_EXTRA_CA_CERTS`) and
/// `ca-key.raw` (0600, the 97 bytes `04 || X || Y || D`). The folder is 0700
/// and not in Time Machine backups.
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
        guard isPrivateFolder(dir), isPrivateFile("\(dir)/\(keyName)", mode: 0o600),
            isPrivateFile("\(dir)/\(derName)", mode: 0o600),
            let der = FileManager.default.contents(atPath: "\(dir)/\(derName)"),
            let key = FileManager.default.contents(atPath: "\(dir)/\(keyName)")
        else { return nil }
        return try? LocalCA.restore(certificateDER: [UInt8](der), keyX963: [UInt8](key))
    }

    /// Writes the three files. A file of an earlier CA is replaced.
    static func save(_ ca: LocalCA, dir: String = dir) throws {
        // A test process never writes the folder of the user.
        if TestProcess.isRunning, dir == Paths.domainsDir { throw POSIXError(.EPERM) }
        let fm = FileManager.default
        var info = stat()
        if lstat(dir, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR { try fm.removeItem(atPath: dir) }
        try fm.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(dir, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try write(Data(try ca.keyX963()), to: "\(dir)/\(keyName)", mode: 0o600)
        try write(Data(ca.der), to: "\(dir)/\(derName)", mode: 0o600)
        try write(Data(X509Builder.pem(ca.der).utf8), to: "\(dir)/\(pemName)", mode: 0o644)
        var url = URL(fileURLWithPath: dir)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Deletes the key first, so that the CA can never sign again, then the folder.
    static func remove(dir: String = dir) {
        if TestProcess.isRunning, dir == Paths.domainsDir { return }
        unlink("\(dir)/\(keyName)")
        try? FileManager.default.removeItem(atPath: dir)
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
