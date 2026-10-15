import Foundation

/// Writes a file that can be a symlink (dotfile managers make them). The
/// write goes to the target and keeps the mode of the target. An atomic
/// write to the link path would replace the link with a plain file.
enum SymlinkWrite {
    /// The file that a write to `path` changes: the end of the link chain.
    /// A relative link is relative to the folder of the link.
    static func target(of path: String) -> String {
        let fm = FileManager.default
        var current = path
        for _ in 0..<16 {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: current) else { break }
            current =
                dest.hasPrefix("/")
                ? dest : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        }
        return current
    }

    /// Writes `data` to the target of `path` and returns that target. The
    /// mode of an existing file stays.
    @discardableResult
    static func write(_ data: Data, to path: String) throws -> String {
        let fm = FileManager.default
        let target = target(of: path)
        let mode = (try? fm.attributesOfItem(atPath: target))?[.posixPermissions]
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target) }
        return target
    }
}
