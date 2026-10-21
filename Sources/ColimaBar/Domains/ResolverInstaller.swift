import Foundation

/// Writes and removes `/etc/resolver/<suffix>` with an administrator prompt
/// (`ResolverFile`). Nothing else in the app touches `/etc`. A test process
/// and a debug run never reach `osascript`: the model gives `apply` a runner,
/// and the system runner refuses in a test process.
enum ResolverInstaller {
    enum Outcome: Equatable, Sendable {
        case done
        case cancelled
        /// The file belongs to another tool (or is a link). Nothing changed.
        case foreign
        case failed(String)
    }

    enum FileState: Equatable, Sendable {
        case missing
        case ours
        case foreign
    }

    typealias Runner = @Sendable ([String]) async -> Shell.Result

    /// Runs `osascript`, except in a test process.
    static let systemRun: Runner = { args in
        guard !TestProcess.isRunning else { return Shell.Result(status: -1, out: "no osascript in a test") }
        return await Shell.run(args, timeout: 120, includeStderr: true)
    }

    /// Reads `<dir>/<suffix>` without root.
    static func inspect(_ suffix: String, dir: String = ResolverFile.dir) -> FileState {
        let path = ResolverFile.path(suffix, dir: dir)
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 4096,
            let data = FileManager.default.contents(atPath: path)
        else { return .foreign }
        return ResolverFile.isOurs(String(decoding: data, as: UTF8.self)) ? .ours : .foreign
    }

    /// `.foreign` when the file exists and is not ours, else nil.
    static func precheck(_ suffix: String, dir: String = ResolverFile.dir) -> Outcome? {
        inspect(suffix, dir: dir) == .foreign ? .foreign : nil
    }

    static func apply(
        new: String?, old: String?, port: Int, dir: String = ResolverFile.dir, run: Runner = systemRun
    ) async -> Outcome {
        guard let shell = ResolverFile.shellCommand(dir: dir, new: new, old: old, port: port) else {
            return .failed("The suffix or the port is not valid.")
        }
        let result = await run(["osascript", "-e", ResolverFile.appleScript(shell)])
        if result.ok { return .done }
        let text = result.out
        if text.contains("-128") || text.localizedCaseInsensitiveContains("User canceled") { return .cancelled }
        if result.status == ResolverFile.foreignExit || text.contains(ResolverFile.foreignToken) { return .foreign }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "status \(result.status)"
        return .failed(String(line.prefix(200)))
    }
}
