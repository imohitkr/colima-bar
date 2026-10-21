import Foundation

/// The space that the VM disk uses on the Mac. Lima keeps the disk files
/// sparse, so the allocated size (st_blocks * 512) is the real use, and the
/// apparent size is the maximum.
struct DiskImageSize: Equatable, Sendable {
    let allocated: Int64
    let apparent: Int64

    /// The files to measure, in the Lima folder:
    /// - INSTANCE/disk (Lima 2: the root disk)
    /// - INSTANCE/diffdisk (older Lima)
    /// - _disks/INSTANCE/datadisk (Colima 0.7 and later: the Docker data disk)
    ///
    /// INSTANCE is `Paths.limaInstance(profile)`: "colima" or "colima-NAME".
    static func candidates(limaDir: String, profile: String) -> [String] {
        let instance = Paths.limaInstance(profile)
        return [
            "\(limaDir)/\(instance)/disk",
            "\(limaDir)/\(instance)/diffdisk",
            "\(limaDir)/_disks/\(instance)/datadisk",
        ]
    }

    /// Sums the regular files that `stat` finds. `stat` returns nil for a
    /// missing file, a symlink or a file that is not regular. The result is
    /// nil when no file was found.
    static func measure(_ paths: [String], stat: (String) -> (blocks: Int64, size: Int64)?) -> DiskImageSize? {
        var allocated: Int64 = 0
        var apparent: Int64 = 0
        var found = false
        for path in paths {
            guard let s = stat(path) else { continue }
            found = true
            allocated += s.blocks * 512
            apparent += s.size
        }
        return found ? DiskImageSize(allocated: allocated, apparent: apparent) : nil
    }
}
