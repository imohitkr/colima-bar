import Darwin
import Foundation

/// The path of the proxy socket of one profile: `DIR/PROFILE.sock`, by
/// default in `~/.cache/colima-bar/profiles`.
///
/// sun_path holds 104 bytes with the closing NUL. `UnixSocket.listen` binds
/// at `PATH.tmp` before it renames the socket, so that name must also fit.
enum ProfileSocket {
    /// The longest socket path in bytes.
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 - ".tmp".utf8.count

    static let suffix = ".sock"

    /// The socket path for `profile` in `dir`, or nil if the name is not a
    /// valid profile name or the path is too long for a unix socket.
    static func path(dir: String, profile: String) -> String? {
        guard ProfileName.isValid(profile) else { return nil }
        let path = "\(dir)/\(profile)\(suffix)"
        return path.utf8.count <= maxPathBytes ? path : nil
    }

    /// The profile of a file name in the folder, for example "work" for
    /// "work.sock". Nil for any other file, such as "work.sock.tmp".
    static func profile(fileName: String) -> String? {
        guard fileName.hasSuffix(suffix) else { return nil }
        let name = String(fileName.dropLast(suffix.count))
        return ProfileName.isValid(name) ? name : nil
    }
}
