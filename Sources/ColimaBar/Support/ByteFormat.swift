import Foundation

enum ByteFormat {
    /// Bytes in one GiB. Colima and the UI say "GB" for this unit.
    static let bytesPerGiB: Int64 = 1 << 30

    static func bytes(_ b: Double) -> String {
        if b <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return i == 0 ? "\(Int(v)) B" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }
}
