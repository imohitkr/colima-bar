import Foundation

/// The state of the volume backup or restore that runs now. The progress
/// strip of the Volumes tab shows it.
struct VolumeTransfer: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case backup, restore }

    let kind: Kind
    let volume: String
    /// The bytes written (backup) or sent (restore).
    var bytes: Int64 = 0
    /// A backup: the size that Docker reports for the volume, or 0. A restore:
    /// the number of bytes to send.
    var total: Double = 0
    /// The place in a Back Up All run, for example 2 of 5.
    var position: Int?
    var count = 1
    var isCancelling = false
    /// A restore that reads the volume and checks the rules, before it sends.
    var isChecking = false

    /// Nil while a backup has no estimate.
    var fraction: Double? {
        if isChecking { return nil }
        switch kind {
        case .backup: return TransferProgress.backupFraction(bytes: bytes, estimate: total)
        case .restore: return TransferProgress.restoreFraction(sent: bytes, total: Int64(total))
        }
    }

    /// The line of the progress strip.
    var text: String {
        if isCancelling { return "Stopping…" }
        if isChecking { return "Checking \(volume)…" }
        let place = position.map { " (\($0) of \(count))" } ?? ""
        switch kind {
        case .backup:
            let done = ByteFormat.bytes(Double(bytes))
            let tail = total > 0 ? "\(done) of about \(ByteFormat.bytes(total))" : done
            return "Backing up \(volume)\(place)… \(tail)"
        case .restore:
            return "Restoring \(volume)… \(Int((fraction ?? 0) * 100))%"
        }
    }
}

/// Why a transfer stopped without the user's Cancel.
enum VolumeTransferStop: Equatable, Sendable {
    case vmStopped, profileChanged

    /// Completes "stopped because …".
    var because: String {
        switch self {
        case .vmStopped: "the VM stopped"
        case .profileChanged: "you chose another profile"
        }
    }
}
