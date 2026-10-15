import Foundation

/// The busy marker that `colima-ctl.sh` writes while a VM action runs.
/// Line 1 is the label. Line 2 is the PID of the script. Older versions
/// wrote the label only.
enum BusyMarker {
    struct Contents: Equatable {
        let label: String
        let pid: Int?
    }

    /// An older marker with no PID is stale after this time.
    static let maxAgeWithoutPID: TimeInterval = 20 * 60

    static func parse(_ text: String) -> Contents {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let label = lines.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Working"
        let pid = lines.dropFirst().first.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        return Contents(label: label, pid: pid)
    }

    /// True if the script that wrote the marker is gone. With a PID, the
    /// owner must run and must have started before the marker was written:
    /// a process that started later only has the same PID. A marker can then
    /// stay for hours while the Mac sleeps. Without a PID, only the age
    /// counts. `ownerStarted` is the start time of the process with the PID,
    /// or nil if there is none.
    static func isStale(
        mtime: Date, now: Date, pid: Int?, ownerStarted: Date?, maxAge: TimeInterval = maxAgeWithoutPID
    ) -> Bool {
        guard pid != nil else { return now.timeIntervalSince(mtime) > maxAge }
        guard let ownerStarted else { return true }
        // The marker is written after the script starts. The 2 seconds absorb
        // the rounding of the file time.
        return ownerStarted.timeIntervalSince(mtime) > 2
    }
}
