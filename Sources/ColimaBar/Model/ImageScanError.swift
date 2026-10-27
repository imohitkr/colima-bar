import Foundation

/// Why a scan did not give a report. `message` is the text for the page and
/// for the notification. It names no image and no vulnerability.
enum ImageScanError: Error, Equatable, Sendable {
    case toolMissing
    case cancelled
    case timeout
    case diskFull
    /// Not enough free space for the temporary file. The value is the space that the export needs.
    case lowDisk(needed: Int64)
    /// Docker could not export the image. The value is a short reason.
    case exportFailed(String)
    /// The scanner has no database and cannot get one.
    case noDatabase
    case offline
    /// The scanner has a database, but it could not update it, or it is too old to use.
    case databaseUpdate
    case badOutput
    /// The last line of the log of the scanner, cut to 120 characters.
    case other(String)

    /// A fixed word for the log. It holds no text of the scanner and no name.
    var kind: String {
        switch self {
        case .toolMissing: "toolMissing"
        case .cancelled: "cancelled"
        case .timeout: "timeout"
        case .diskFull: "diskFull"
        case .lowDisk: "lowDisk"
        case .exportFailed: "exportFailed"
        case .noDatabase: "noDatabase"
        case .offline: "offline"
        case .databaseUpdate: "databaseUpdate"
        case .badOutput: "badOutput"
        case .other: "other"
        }
    }

    var message: String {
        switch self {
        case .toolMissing: "The scanner is gone. Install Trivy or Grype, then scan again."
        case .cancelled: "The scan was cancelled."
        case .timeout: "The scan took too long. ColimaBar stopped it."
        case .diskFull: "The disk of your Mac is full."
        case .lowDisk(let needed):
            "Not enough free disk space to export the image (needs ~\(ByteFormat.bytes(Double(needed))))."
        case .exportFailed(let reason): "Docker could not export the image: \(reason)"
        case .noDatabase: "Connect to the internet for the first scan. The scanner downloads its database."
        case .offline: "The scanner could not reach the internet. Check the connection, then scan again."
        case .databaseUpdate:
            "The scanner could not update its vulnerability database. Check the connection, then scan again."
        case .badOutput: "ColimaBar could not read the report of the scanner."
        case .other(let line): line.isEmpty ? "The scanner failed." : line
        }
    }

    /// The reason of a failed export, from the text of Docker. The containerd
    /// image store cannot save an image whose other platforms are not on disk.
    static func export(_ reason: String) -> ImageScanError {
        let lower = reason.lowercased()
        if lower.contains("digest"), lower.contains("not found") {
            return .exportFailed("it is not on disk for every platform. Pull the image again.")
        }
        return .exportFailed(reason)
    }

    /// Sorts the end of a scanner process. `status` is its exit status (-1 if
    /// it did not start). `log` is its output, stdout and stderr together.
    /// `timedOut` means that ColimaBar stopped it at its time limit.
    /// `hadDatabase` means that the scanner had a database when the scan started.
    static func classify(status: Int32, log: String, timedOut: Bool = false, hadDatabase: Bool = false)
        -> ImageScanError
    {
        // Shell starts a program through `env`, so a missing program gives status 127.
        if timedOut { return .timeout }
        if status == -1 || status == 127 { return .toolMissing }
        let lower = log.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        let noDatabaseWords = [
            "cannot be specified on the first run", "db does not exist", "database does not exist",
            "no vulnerability database",
        ]
        if has(noDatabaseWords) {
            return .noDatabase
        }
        if has(["max allowed age", "max allowed built age", "database was built"]) { return .databaseUpdate }
        if has(["unable to update vulnerability database", "failed to download", "failed to load vulnerability db"]) {
            return hadDatabase ? .databaseUpdate : .noDatabase
        }
        if has(["no such host", "dial tcp", "i/o timeout", "network is unreachable"]) { return .offline }
        if has(["no space left"]) { return .diskFull }
        if has(["deadline exceeded"]) || status == 15 || status == 9 { return .timeout }
        let last =
            log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return .other(String(last.prefix(120)))
    }
}
