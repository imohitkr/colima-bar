import Foundation

/// The result of Return Free Space: `fstrim -av` in the VM. The functions
/// are pure.
enum DiskTrim {
    /// The Mac side can lag behind the guest. ColimaBar measures the disk
    /// image again after this wait.
    static let settleDelay: Duration = .seconds(2)
    /// A disk image that is smaller by less than this is "not smaller".
    static let smallerLimit: Int64 = 1 << 20

    /// The sum of the trimmed bytes in the output of `fstrim -av`, or nil
    /// when no line has them. util-linux prints
    /// "/: 1.2 GiB (1288490188 bytes) trimmed on /dev/vda1" (newer) and
    /// "/: 1288490188 bytes were trimmed" (older). The function reads both.
    static func trimmedBytes(in out: String) -> Int64? {
        let newer = /\((\d+) bytes\) trimmed/
        let older = /(\d+) bytes were trimmed/
        var total: Int64?
        for line in out.split(separator: "\n") where !line.hasPrefix("COLIMABAR_NOTIFY:") {
            let match = line.firstMatch(of: newer).map { $0.1 } ?? line.firstMatch(of: older).map { $0.1 }
            guard let digits = match, let n = Int64(digits) else { continue }
            total = (total ?? 0) + n
        }
        return total
    }

    /// The notification after a good run.
    static func message(profile: String, trimmed: Int64?, before: DiskImageSize?, after: DiskImageSize?) -> String {
        let who = "The VM of profile '\(profile)'"
        func size(_ b: Int64) -> String { ByteFormat.bytes(Double(b)) }
        guard let after else {
            guard let trimmed else { return "\(who) ran fstrim." }
            return "\(who) trimmed \(size(trimmed)). ColimaBar could not find the disk image to measure it."
        }
        if let before, before.allocated - after.allocated >= smallerLimit {
            return "Returned free space of profile '\(profile)' to the Mac. "
                + "The disk image went from \(size(before.allocated)) to \(size(after.allocated))."
        }
        let now = "The disk image on the Mac is \(size(after.allocated))."
        guard let trimmed else { return "\(who) ran fstrim. \(now)" }
        if trimmed == 0 { return "\(who) had no free space to return. \(now)" }
        return "\(who) trimmed \(size(trimmed)). The disk image on the Mac is still \(size(after.allocated))."
    }
}
