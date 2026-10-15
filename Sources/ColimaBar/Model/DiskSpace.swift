import Foundation

/// Free space in the VM and on the Mac, and the rules for it.
enum DiskSpace {
    /// The space of one file system.
    struct Usage: Equatable, Sendable {
        let usedKB: Int64
        let availKB: Int64

        var availBytes: Int64 { availKB * 1024 }
        /// The used share in percent, rounded up as `df` does.
        var usedPercent: Int {
            let total = usedKB + availKB
            return total > 0 ? Int((usedKB * 100 + total - 1) / total) : 0
        }
    }

    static let gigabyte: Int64 = 1_000_000_000

    /// The numbers of `df -Pk PATH`. A data line ends with the used and
    /// available blocks, the capacity (such as "42%") and the mount point.
    static func parse(df output: String) -> Usage? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let w = line.split(separator: " ")
            guard w.count >= 6, w[w.count - 2].hasSuffix("%"),
                let used = Int64(w[w.count - 4]), let avail = Int64(w[w.count - 3])
            else { continue }
            return Usage(usedKB: used, availKB: avail)
        }
        return nil
    }

    /// The status for the disk of the VM: 95% used or less than 2 GB free is a
    /// problem, 85% used is a warning.
    static func vm(_ u: Usage) -> (status: DoctorResult.Status, text: String) {
        let text = "VM disk \(u.usedPercent)% used, \(ByteFormat.bytes(Double(u.availBytes))) free"
        if u.usedPercent >= 95 || u.availBytes < 2 * gigabyte { return (.problem, text) }
        if u.usedPercent >= 85 { return (.warning, text) }
        return (.ok, text)
    }

    /// The status for the Mac: less than 5 GB free is a problem, less than
    /// 20 GB is a warning.
    static func mac(freeBytes: Int64) -> (status: DoctorResult.Status, text: String) {
        let text = "Mac \(ByteFormat.bytes(Double(freeBytes))) free"
        if freeBytes < 5 * gigabyte { return (.problem, text) }
        if freeBytes < 20 * gigabyte { return (.warning, text) }
        return (.ok, text)
    }
}
