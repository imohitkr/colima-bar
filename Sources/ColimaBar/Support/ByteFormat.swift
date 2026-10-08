import Foundation

enum ByteFormat {
    /// Bytes in one GiB. Colima and the UI say "GB" for this unit.
    static let bytesPerGiB: Int64 = 1 << 30

    /// A size in bytes as a decimal number of GiB, rounded to 3 decimals.
    /// Colima stores a decimal memory such as 0.3 GiB with a small error in
    /// bytes, and the rounding removes it.
    static func gib(bytes: Int64) -> Double {
        (Double(bytes) / Double(bytesPerGiB) * 1000).rounded() / 1000
    }

    /// A decimal number of GiB as Colima writes it: "2.5", or "8" with no
    /// ".0" for a whole value. colima-ctl.sh gets memory in this form.
    static func gibText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

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
