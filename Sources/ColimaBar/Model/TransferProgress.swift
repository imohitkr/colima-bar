import Foundation

/// The progress of a volume transfer, as pure functions.
enum TransferProgress {
    /// A backup has no known size. `estimate` is the size that Docker reports
    /// for the volume. With it, the value is below 1 until the end. Without
    /// it (0), the value is nil and the bar has no end.
    static func backupFraction(bytes: Int64, estimate: Double) -> Double? {
        guard estimate > 0 else { return nil }
        return min(0.99, max(0, Double(bytes) / estimate))
    }

    /// A restore knows the number of bytes to send.
    static func restoreFraction(sent: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(sent) / Double(total)))
    }
}
