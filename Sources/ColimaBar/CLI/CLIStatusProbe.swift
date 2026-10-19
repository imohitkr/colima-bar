import Darwin
import Foundation

/// The reads behind `colimabar status`. They only read: no VM starts, no
/// file changes, no marker goes away.
enum CLIStatusProbe {
    /// What is at `path`. Nothing runs and nothing connects: one `lstat`.
    /// A socket at the path of a proxy is the proxy of a running app. With no
    /// app, it is a leftover of a crash (`stale`). `isProxyPath` is false for
    /// a path that no proxy of ColimaBar owns: a socket there is `other`.
    static func socketKind(path: String, appRunning: Bool, isProxyPath: Bool = true) -> CLIStatus.SocketKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFSOCK: return isProxyPath ? (appRunning ? .proxy : .stale) : .other
        case S_IFLNK: return .link
        default: return .other
        }
    }

    /// The label of the VM action of `profile`, read from the busy marker, or
    /// nil. A stale marker counts as no marker, and it stays: the command
    /// never deletes a file of the app (see `BusyMarker`).
    static func busyLabel(
        profile: String, path: String? = nil, now: Date = Date(),
        startTime: (Int) -> Date? = { ProcessProbe.startTime(pid: $0) }
    ) -> String? {
        let file = path ?? Paths.busy(profile)
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date,
            let text = try? String(contentsOfFile: file, encoding: .utf8)
        else { return nil }
        let marker = BusyMarker.parse(text)
        let stale = BusyMarker.isStale(
            mtime: mtime, now: now, pid: marker.pid, ownerStarted: marker.pid.flatMap(startTime))
        return stale ? nil : marker.label
    }

    /// The profiles of the output of `colima list -j`: one JSON object a line.
    static func rows(from output: String) -> [String: CLIStatus.Row] {
        let decoder = JSONDecoder()
        var rows: [String: CLIStatus.Row] = [:]
        for line in output.split(separator: "\n") {
            guard let item = try? decoder.decode(ColimaListJSON.self, from: Data(line.utf8)) else { continue }
            rows[item.name ?? "default"] = CLIStatus.Row(
                status: item.status, runtime: item.runtime, arch: item.arch, cpus: item.cpus,
                memoryGiB: item.memory.map { ByteFormat.gib(bytes: $0) },
                diskGiB: item.disk.map { Int($0 / ByteFormat.bytesPerGiB) })
        }
        return rows
    }

    /// The result of `colima list -j`.
    enum List: Equatable, Sendable {
        case notInstalled
        case failed
        case listed([String: CLIStatus.Row])
    }

    /// Runs `colima list -j`. It is read-only and takes about 0.2 s.
    static func list() async -> List {
        guard Shell.which("colima") != nil else { return .notInstalled }
        let r = await Shell.run(["colima", "list", "-j"], timeout: 10)
        return r.ok ? list(from: r.out) : .failed
    }

    /// The list for the output of `colima list -j`. No output is a list with
    /// no profile. Output with no readable line is not: it counts as failed,
    /// so `stop` never says "already stopped" for a VM that it cannot see.
    static func list(from output: String) -> List {
        let found = rows(from: output)
        let blank = output.allSatisfy(\.isWhitespace)
        return found.isEmpty && !blank ? .failed : .listed(found)
    }

    /// Reads all facts for the status of `profile`.
    @MainActor
    static func gather(profile: String, selected: String, now: Date = Date()) async -> CLIStatus.Inputs {
        let list = await list()
        let listing: CLIStatus.Listing
        switch list {
        case .notInstalled: listing = .notInstalled
        case .failed: listing = .failed
        case .listed(let rows): listing = .listed(rows[profile])
        }
        let app = AppStatusFile.read(now: now)
        // An older app writes no status file. Ask macOS if it runs.
        let runsWithoutFile = app == nil && CLIRunner.appIsRunning()
        let isSelected = profile == selected
        let ownPath = Paths.profileSocket(profile)
        let socketPath = isSelected ? Paths.proxySocket : ownPath ?? Paths.socket(profile)
        let context = Routing.currentContext().map { $0.isEmpty ? "default" : $0 }
        return CLIStatus.Inputs(
            version: AppDelegate.version, profile: profile, selectedInApp: isSelected, listing: listing,
            action: busyLabel(profile: profile, now: now), autoStart: Defaults.bool(.autoStart) ?? true,
            autoStop: Defaults.bool(.autoStop) ?? false,
            idleMinutes: Defaults.int(.autoStopMinutes).map(IdleMinutes.clamp) ?? 30, app: app,
            appRunsWithoutFile: runsWithoutFile, socketPath: socketPath,
            socketKind: socketKind(
                path: socketPath, appRunning: app != nil || runsWithoutFile, isProxyPath: isSelected || ownPath != nil),
            dockerContext: context, now: now)
    }
}
