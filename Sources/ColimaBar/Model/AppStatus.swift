import Foundation

/// What the running app tells the `colimabar` command: its PID, its version
/// and when auto-stop stops each profile. The command has no other way to
/// know these facts. The app writes it to `Paths.appStatus` (see
/// `AppStatusFile`).
struct AppStatus: Equatable, Sendable {
    /// The version of the file. A reader refuses another one.
    static let format = 1

    var pid: Int
    var version: String
    /// When auto-stop stops each profile that is idle, by profile.
    var autoStopAt: [String: Date]

    /// The JSON of the file: `{"format":1,"pid":N,"version":"X","autoStopAt":{"default":"2026-10-19T09:12:00Z"}}`.
    /// The dates have whole seconds, in UTC.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // The encoder cannot fail for these types.
        return (try? encoder.encode(File(format: Self.format, pid: pid, version: version, autoStopAt: autoStopAt)))
            ?? Data()
    }

    /// Reads the JSON. Nil for any other format, and for data that is not a status.
    static func decode(_ data: Data) -> AppStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.format == format, file.pid > 0 else {
            return nil
        }
        return AppStatus(pid: file.pid, version: file.version, autoStopAt: file.autoStopAt)
    }

    private struct File: Codable {
        let format: Int
        let pid: Int
        let version: String
        let autoStopAt: [String: Date]
    }

    /// True if the app must write the file again: a profile got or lost a
    /// stop time, or a stop time moved by 1 second or more. A stop time
    /// moves later while the Mac sleeps. `old` is nil before the first write.
    static func needsWrite(old: [String: Date]?, new: [String: Date]) -> Bool {
        guard let old else { return true }
        guard Set(old.keys) == Set(new.keys) else { return true }
        return new.contains { name, date in
            old[name].map { abs(date.timeIntervalSince($0)) >= 1 } ?? true
        }
    }

    /// True if the app that wrote the file does not run now. The rule is the
    /// one of the busy marker: the PID must belong to a process that started
    /// before the file was written. A PID that another process took after a
    /// crash does not count. `ownerStarted` is nil if no process has the PID.
    func isStale(mtime: Date, now: Date, ownerStarted: Date?) -> Bool {
        BusyMarker.isStale(mtime: mtime, now: now, pid: pid, ownerStarted: ownerStarted)
    }
}
