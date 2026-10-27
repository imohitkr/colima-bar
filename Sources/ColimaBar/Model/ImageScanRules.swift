import Foundation

/// The rules of the image scan. The functions are pure. `ColimaModel` reads
/// the inputs when the user clicks.
enum ImageScanRules {
    /// The scanner may run this long (seconds) before ColimaBar stops it.
    static let scanTimeout: TimeInterval = 900
    /// The export stops when Docker sends no byte for this long (seconds).
    static let exportStall: TimeInterval = 60
    /// The most bytes of the report file that ColimaBar reads.
    static let maxReportBytes = 64 * 1024 * 1024
    /// The free space that the export needs beyond 2.4 times the image size. The export file is about
    /// the image size, and the scanner unpacks the layers into `$TMPDIR`.
    static let spareBytes: Int64 = 2 * ByteFormat.bytesPerGiB

    /// The scan may start: the setting is on, a scanner exists, the VM runs
    /// and nothing else changes it. A debug run never scans.
    static func mayScan(
        enabled: Bool, scannerFound: Bool, isDebug: Bool, updateRestarting: Bool, running: Bool,
        hasDockerSocket: Bool, waking: Bool, recreating: Bool, transferring: Bool, proxyTransfers: Int,
        scanning: Bool
    ) -> Bool {
        enabled && scannerFound && !isDebug && !updateRestarting && running && hasDockerSocket && !waking
            && !recreating && !transferring && proxyTransfers == 0 && !scanning
    }

    /// The free space that the export of an image of `imageSize` bytes needs.
    static func neededSpace(imageSize: Int64) -> Int64 {
        Int64(Double(max(0, imageSize)) * 2.4) + spareBytes
    }

    static func hasSpace(free: Int64, imageSize: Int64) -> Bool { free >= neededSpace(imageSize: imageSize) }

    /// The export stops after this many bytes. A tar is about the size of the image.
    static func byteCap(imageSize: Int64) -> Int64 { max(0, imageSize) * 2 }

    /// The ID of an image without `sha256:`, or nil if it is not 12 to 64
    /// lower-case hex digits. Only such an ID goes into a request or a file name.
    static func normalizedID(_ id: String) -> String? {
        let hex = id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
        guard (12...64).contains(hex.utf8.count),
            hex.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
        else { return nil }
        return hex
    }

    static func shortID(_ hex: String) -> String { String(hex.prefix(12)) }
}
