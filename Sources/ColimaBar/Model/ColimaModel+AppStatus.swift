import Foundation
import os

private let appStatusLog = Logger(category: "app-status")

/// The status file for the `colimabar` command. Only a normal run writes it.
extension ColimaModel {
    /// Writes `Paths.appStatus` when a normal run starts, when a profile gets
    /// or loses an auto-stop time, when a time moves by 1 second or more, and
    /// when the file is gone. A debug run and the command never write it.
    /// The heartbeat calls it, so it costs one `stat` when nothing changed.
    /// `write` and `logFailure` are parameters so a test can count them.
    func publishAppStatus(
        path: String = Paths.appStatus,
        write: (AppStatus, String) throws -> Void = { try AppStatusFile.write($0, path: $1) },
        logFailure: (String) -> Void = { appStatusLog.error("status file not written: \($0, privacy: .public)") }
    ) {
        guard !isDebug else { return }
        let times = autoStopTimes()
        guard AppStatus.needsWrite(old: appStatusTimes, new: times) || !FileManager.default.fileExists(atPath: path)
        else { return }
        let status = AppStatus(pid: Int(getpid()), version: AppDelegate.version, autoStopAt: times)
        do {
            try write(status, path)
            appStatusTimes = times
            appStatusWriteFailed = false
        } catch {
            // Log once for a run of failures, not at each heartbeat.
            if !appStatusWriteFailed {
                logFailure(error.localizedDescription)
            }
            appStatusWriteFailed = true
        }
    }
}
