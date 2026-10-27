import Foundation

/// The last scan that ColimaBar ran: which image, with which scanner, and how
/// far it is. A new scan replaces it. The page and the Images tab read it.
struct ImageScanState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// ColimaBar exports the image from the VM. `total` is the image size, or 0 if unknown.
        case exporting(bytes: Int64, total: Int64)
        /// The scanner runs. `firstRun` is true if it has no database yet and has to download one.
        case scanning(firstRun: Bool)
        case done(ImageScanReport)
        case failed(ImageScanError)
    }

    let profile: String
    /// The image ID without `sha256:`.
    let imageID: String
    let imageName: String
    let tool: ImageScanner
    var phase: Phase

    var isRunning: Bool {
        switch phase {
        case .exporting, .scanning: true
        case .done, .failed: false
        }
    }

    var report: ImageScanReport? {
        if case .done(let report) = phase { return report }
        return nil
    }

    /// The line under the header of the page, or nil when the report shows.
    var statusLine: String? {
        switch phase {
        case .exporting(let bytes, let total):
            let done = ByteFormat.bytes(Double(bytes))
            guard total > 0 else { return "Exporting the image… \(done)" }
            return "Exporting the image… \(done) / \(ByteFormat.bytes(Double(total)))"
        case .scanning(let firstRun):
            return firstRun
                ? "Downloading the vulnerability database (first scan, can take minutes)…" : "Scanning…"
        case .done: return nil
        case .failed(let error): return error.message
        }
    }
}
