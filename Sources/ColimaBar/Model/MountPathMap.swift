import Foundation

/// Maps a path in the VM back to the folder of the Mac that Colima shares.
/// Colima mounts each `location` of colima.yaml at the same path in the VM,
/// unless the entry has a `mountPoint`. An explicit `mounts: []` mounts the
/// home folder.
enum MountPathMap {
    /// The path on the Mac, or nil if no mount covers `vmPath`. It does not
    /// check that the path exists. A path with `..` has no match.
    static func macPath(vmPath: String, mounts: [VMMount], defaultHome: Bool, home: String) -> String? {
        guard let target = parts(vmPath) else { return nil }
        var all = mounts
        if defaultHome { all.append(VMMount(location: home, writable: true)) }
        var best: (depth: Int, path: String)?
        for mount in all {
            guard let location = parts(expand(mount.location, home: home)),
                let inVM = parts(expand(mount.mountPoint ?? mount.location, home: home)),
                target.starts(with: inVM), inVM.count > (best?.depth ?? -1)
            else { continue }
            let rest = target.dropFirst(inVM.count)
            best = (inVM.count, "/" + (location + rest).joined(separator: "/"))
        }
        return best?.path
    }

    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    /// The parts of an absolute path, or nil for a relative path or a path
    /// with `..`. Empty parts and `.` fall away, so a trailing slash is fine.
    private static func parts(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        let all = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !all.contains("..") else { return nil }
        return all.filter { $0 != "." }
    }
}
