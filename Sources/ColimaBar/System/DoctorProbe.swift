import Foundation
import os

/// All the I/O of Doctor. Each function reads one part of the system and
/// returns a piece of `DoctorInputs`. None of them changes anything, and none
/// of them starts the VM: `docker context ls` and `docker --version` do not
/// talk to the daemon.
enum DoctorProbe {
    private static let log = Logger(category: "doctor")

    /// Paths of the tools, and their versions. Uses `docker --version`, not
    /// `docker version`, because that one calls the daemon and starts the VM.
    static func tools() async -> DoctorInputs.Tools {
        async let colima = Shell.run(["colima", "version"], timeout: 5)
        async let lima = Shell.run(["limactl", "--version"], timeout: 5)
        async let docker = Shell.run(["docker", "--version"], timeout: 5)
        let paths = (colima: Shell.which("colima"), limactl: Shell.which("limactl"), docker: Shell.which("docker"))
        // A tool that exists but did not run has no version (nil). Output that
        // holds no version gives "unknown".
        func version(_ path: String?, _ r: Shell.Result) -> String? {
            guard path != nil, r.ok else { return nil }
            return ToolVersions.version(in: r.out) ?? "unknown"
        }
        let v = await ToolVersions(
            colima: version(paths.colima, colima), lima: version(paths.limactl, lima),
            docker: version(paths.docker, docker))
        return DoctorInputs.Tools(
            colimaPath: paths.colima, limactlPath: paths.limactl, dockerPath: paths.docker, versions: v)
    }

    /// The versions alone. A later upgrade guard can save them at each good start.
    static func versions() async -> ToolVersions { await tools().versions }

    /// The names of the docker contexts that exist, or nil if the docker CLI failed.
    static func existingContexts() async -> Set<String>? {
        let ls = await Shell.run(["docker", "context", "ls", "--format", Routing.listFormat], timeout: 10)
        return ls.ok ? Routing.existingContexts(listing: ls.out) : nil
    }

    /// The `DOCKER_HOST` that the startup files of the login shell set. It
    /// reads the text of the files and runs no user code.
    static func shellHost(env: [String: String] = ProcessInfo.processInfo.environment) -> DoctorInputs.ShellInput {
        let shell = loginShell() ?? env["SHELL"] ?? "/bin/zsh"
        let flavor = ShellStartupScan.flavor(shell: shell)
        let paths = ShellStartupScan.files(flavor: flavor, home: Paths.home, zdotdir: env["ZDOTDIR"])
        var files: [(path: String, text: String)] = []
        var unreadable: [String] = []
        for p in paths {
            guard (try? FileManager.default.attributesOfItem(atPath: p)) != nil else { continue }
            // One byte that is not UTF-8 must not hide the whole file.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
                unreadable.append(p)
                continue
            }
            files.append((path: p, text: String(decoding: data, as: UTF8.self)))
        }
        return DoctorInputs.ShellInput(
            name: (shell as NSString).lastPathComponent,
            found: ShellStartupScan.lastAssignment(files: files, flavor: flavor), unreadable: unreadable)
    }

    private static func loginShell() -> String? {
        guard let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell else { return nil }
        return String(cString: sh)
    }

    /// The docker config file, and which credential helpers exist. It reads
    /// the names of the helpers only, never `auths`.
    static func credentials(env: [String: String] = ProcessInfo.processInfo.environment) -> DoctorInputs.Credentials {
        let path = Paths.dockerConfig(env: env, home: Paths.home)
        var data = Data()
        if case .data(let d) = DockerConfigFile.read(path: path) { data = d }
        guard let config = DockerConfig.parse(data) else {
            return DoctorInputs.Credentials(config: nil, available: [])
        }
        let folders =
            Shell.searchPath.split(separator: ":").map(String.init) + [
                "\(Paths.home)/.docker/bin", "\(Paths.home)/.local/bin",
            ]
        let names = config.helperNames.union(["osxkeychain"])
        let found = names.filter { name in
            folders.contains { FileManager.default.isExecutableFile(atPath: "\($0)/docker-credential-\(name)") }
        }
        return DoctorInputs.Credentials(config: config, available: found)
    }

    /// True if the docker config file exists and ColimaBar cannot read it.
    static func dockerConfigUnreadable(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        DockerConfigFile.read(path: Paths.dockerConfig(env: env, home: Paths.home)) == .unreadable
    }

    /// The folders where docker looks for CLI plugins, in its order.
    static func pluginFolders(extraDirs: [String], home: String) -> [String] {
        extraDirs + [
            "\(home)/.docker/cli-plugins", "/usr/local/lib/docker/cli-plugins",
            "/usr/local/libexec/docker/cli-plugins", "/usr/lib/docker/cli-plugins",
            "/usr/libexec/docker/cli-plugins",
        ]
    }

    /// Looks for `docker-buildx` and `docker-compose` in the folders of docker.
    static func plugins(env: [String: String] = ProcessInfo.processInfo.environment) -> [DoctorInputs.PluginSearch] {
        let path = Paths.dockerConfig(env: env, home: Paths.home)
        var config = DockerConfig()
        if case .data(let d) = DockerConfigFile.read(path: path) { config = DockerConfig.parse(d) ?? DockerConfig() }
        var folders = pluginFolders(extraDirs: config.pluginDirs, home: Paths.home)
        let searched = Set(folders)
        folders.append(DoctorRules.homebrewPluginFolder)
        return ["docker-buildx", "docker-compose"].map { name in
            var seen = Set<String>()
            let entries = folders.compactMap { folder -> DoctorInputs.PluginEntry? in
                // The Homebrew folder can be in the list twice.
                guard seen.insert(folder).inserted else { return nil }
                return DoctorInputs.PluginEntry(
                    folder: folder, state: pluginState("\(folder)/\(name)"),
                    searchedByDocker: searched.contains(folder))
            }
            return DoctorInputs.PluginSearch(name: name, entries: entries)
        }
    }

    /// Missing, working or broken (a link to nothing, or a file that cannot run).
    static func pluginState(_ path: String) -> DoctorInputs.PluginEntry.State {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: path)) != nil else { return .missing }
        return fm.isExecutableFile(atPath: path) ? .works : .broken
    }

    /// The pid files of Lima that it cannot use (`colima-ctl.sh stale-files`).
    /// A line outside Lima's folder is dropped. A failed script is not an
    /// empty list: `failure` has its exit status.
    static func staleFiles(
        profile: String, limaDir: String, daemonPidFile: String
    ) async -> (files: [StaleLimaFile], failure: Int32?, unparsed: Int) {
        let r = await Shell.run(
            [Paths.ctl, CtlAction.staleFiles.rawValue], timeout: 15, extraEnv: ["COLIMABAR_PROFILE": profile])
        guard r.ok else {
            log.error("colima-ctl.sh stale-files failed (exit \(r.status))")
            return ([], r.status, 0)
        }
        let s = StaleLimaFile.scan(r.out, limaDir: limaDir, daemonPidFile: daemonPidFile)
        if s.dropped > 0 { log.error("stale-files: \(s.dropped) line(s) not read") }
        return (s.files, nil, s.dropped)
    }

    /// The free space of the VM (only while it runs) and of the Mac.
    static func disk(profile: String, running: Bool, runtime: String, limaDir: String) async -> DoctorInputs.Disk {
        var disk = DoctorInputs.Disk()
        if running {
            let path = runtime == "containerd" ? "/var/lib/containerd" : "/var/lib/docker"
            let df = await Shell.run(["colima", "ssh", "--profile", profile, "--", "df", "-Pk", path], timeout: 10)
            if !df.ok {
                disk.vmError = "colima ssh df failed (exit \(df.status))"
            } else if let usage = DiskSpace.parse(df: df.out) {
                disk.vm = usage
            } else {
                disk.vmError = "the output of colima ssh df was not read"
            }
        }
        let folder = FileManager.default.fileExists(atPath: limaDir) ? limaDir : Paths.home
        disk.macFreeBytes =
            (try? URL(fileURLWithPath: folder).resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        return disk
    }
}
