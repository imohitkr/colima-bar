import Foundation

/// Everything that the checks of Doctor read. `DoctorProbe` and the model
/// fill it in. `DoctorRules` turns it into results without any I/O, so tests
/// can build any case.
struct DoctorInputs: Equatable, Sendable {
    var profile = "default"
    /// The home folder, to show paths with `~`.
    var home = ""
    var autoStart = true
    /// The stable socket as a docker host, for example `unix:///Users/me/.cache/colima-bar/docker.sock`.
    var stableHost = ""
    var tools = Tools()
    var context = DockerContext()
    var routes = Routes()
    var shell = ShellInput()
    var credentials = Credentials()
    var plugins: [PluginSearch] = []
    var vm = VM()
    var staleFiles: [StaleLimaFile] = []
    /// The exit status of `stale-files` if it failed. Then `staleFiles` is empty
    /// and means nothing.
    var staleListFailure: Int32?
    /// The lines of `stale-files` that ColimaBar could not read.
    var staleUnparsed = 0
    /// The docker config file exists but ColimaBar cannot read it. Then no
    /// check trusts the config and no fix edits it.
    var dockerConfigUnreadable = false
    var disk = Disk()

    struct Tools: Equatable, Sendable {
        var colimaPath: String?
        var limactlPath: String?
        var dockerPath: String?
        var versions = ToolVersions()
    }

    struct DockerContext: Equatable, Sendable {
        /// The `currentContext` of the docker config file. "" is the default
        /// context. Nil if the file cannot be read.
        var current: String? = ""
        /// The contexts that exist. Nil if the docker CLI did not answer.
        var existing: Set<String>? = []
    }

    struct Routes: Equatable, Sendable {
        /// The raw value of `launchctl getenv DOCKER_HOST`.
        var launchdHost = ""
        /// The `docker.host` line of `~/.testcontainers.properties`.
        var testcontainersHost: String?
    }

    struct ShellInput: Equatable, Sendable {
        var name = "zsh"
        var found: ShellStartupScan.Found?
        /// The startup files that exist but could not be read.
        var unreadable: [String] = []
    }

    struct Credentials: Equatable, Sendable {
        /// Nil if the docker config file is not valid JSON.
        var config: DockerConfig? = DockerConfig()
        /// The helpers that exist as `docker-credential-NAME`, among the ones
        /// that the config names and `osxkeychain`.
        var available: Set<String> = []
    }

    /// The search for one CLI plugin, for example `docker-buildx`.
    struct PluginSearch: Equatable, Sendable {
        let name: String
        /// The folders in the order that docker searches them, then the
        /// Homebrew folder when docker does not search it.
        let entries: [PluginEntry]
    }

    struct PluginEntry: Equatable, Sendable {
        enum State: Equatable, Sendable { case missing, works, broken }
        let folder: String
        let state: State
        /// False for the Homebrew folder when `cliPluginsExtraDirs` lacks it.
        let searchedByDocker: Bool
    }

    struct VM: Equatable, Sendable {
        /// The row of the selected profile in the last `colima list`.
        var selected: ProfileRow?
        var others: [ProfileRow] = []
        /// `colima list` failed or timed out, so the rows may be old.
        var listFailed = false
    }

    struct Disk: Equatable, Sendable {
        /// The space of the VM. Nil while the VM is stopped or when `df` failed.
        var vm: DiskSpace.Usage?
        /// Why the VM space is unknown while the VM runs, for example
        /// "colima ssh df failed (exit 255)".
        var vmError: String?
        var macFreeBytes: Int64?
    }
}
