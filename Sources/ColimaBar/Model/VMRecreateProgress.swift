import Foundation

/// The state of the VM type change that runs now. The strip under the
/// header of the dashboard shows it.
struct VMRecreateProgress: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case preparing, backingUp, savingImages, recreating, waiting, restoring, loadingImages
    }

    let profile: String
    var step: Step
    /// The volume that the backup or restore works on.
    var volume = ""
    /// The bytes written or sent in this step.
    var bytes: Int64 = 0
    /// The size to expect (an estimate for a backup), or 0.
    var total: Double = 0
    /// The place in a run of several volumes, for example 2 of 5.
    var position: Int?
    var count = 1
    var isCancelling = false

    /// ColimaBar cannot stop the script, or the wait for Docker.
    var canCancel: Bool { ![.recreating, .waiting].contains(step) && !isCancelling }

    /// Nil while the step has no known size.
    var fraction: Double? {
        switch step {
        case .backingUp, .savingImages: TransferProgress.backupFraction(bytes: bytes, estimate: total)
        case .restoring, .loadingImages:
            total > 0 ? TransferProgress.restoreFraction(sent: bytes, total: Int64(total)) : nil
        case .preparing, .recreating, .waiting: nil
        }
    }

    /// The line of the strip.
    var text: String {
        if isCancelling { return "Stopping…" }
        let place = position.map { " (\($0) of \(count))" } ?? ""
        switch step {
        case .preparing: return "Preparing…"
        case .backingUp:
            return "Backing up \(volume)\(place)… \(sizeText)"
        case .savingImages: return "Saving images… \(sizeText)"
        case .recreating: return "Recreating the VM…"
        case .waiting: return "Waiting for Docker…"
        case .restoring: return "Restoring \(volume)\(place)…"
        case .loadingImages: return "Loading images… \(Int((fraction ?? 0) * 100))%"
        }
    }

    private var sizeText: String {
        let done = ByteFormat.bytes(Double(bytes))
        return total > 0 ? "\(done) of about \(ByteFormat.bytes(total))" : done
    }
}
