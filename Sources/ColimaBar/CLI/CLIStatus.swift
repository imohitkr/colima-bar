import Foundation

/// The answer of `colimabar status`. The JSON is the contract for scripts
/// (`schemaVersion` 1): every key is always there, with `null` when it has
/// no value. A new key does not change the version. A rename, a removal or a
/// change of a type raises it. The text is for people and can change.
struct CLIStatus: Equatable, Sendable {
    static let schemaVersion = 1

    enum State: String, Sendable {
        case running, stopped, broken, missing, notInstalled, unknown
    }

    /// What is at the socket path. `proxy` is a socket while the app runs.
    enum SocketKind: String, Sendable {
        case proxy, link, stale, missing, other
    }

    struct VM: Equatable, Sendable {
        var state: State
        /// The status of `colima list`, for example "Running".
        var colimaStatus: String?
        /// The label of the action that runs now, for example "Starting".
        var action: String?
        var runtime: String?
        var arch: String?
        var cpus: Int?
        var memoryGiB: Double?
        var diskGiB: Int?
    }

    struct AutoStop: Equatable, Sendable {
        var enabled: Bool
        var idleMinutes: Int
        var stopsAt: Date?
        var minutesLeft: Int?
    }

    struct Socket: Equatable, Sendable {
        var path: String
        var kind: SocketKind
    }

    struct App: Equatable, Sendable {
        var running: Bool
        var version: String?
    }

    var version: String
    var profile: String
    var selectedInApp: Bool
    var vm: VM
    var autoStart: Bool
    var autoStop: AutoStop
    var socket: Socket
    /// The docker context. "default" for the default context. Nil if the docker config file cannot be read.
    var dockerContext: String?
    var app: App

    // MARK: - Making it

    /// A row of `colima list -j`.
    struct Row: Equatable, Sendable {
        var status: String
        var runtime: String?
        var arch: String?
        var cpus: Int?
        var memoryGiB: Double?
        var diskGiB: Int?
    }

    /// What `colima list -j` said about the profile.
    enum Listing: Equatable, Sendable {
        case notInstalled
        /// Colima gave no list: it failed or timed out.
        case failed
        /// The list, with the row of the profile, or nil if the profile is not in it.
        case listed(Row?)
    }

    /// The facts that `CLIStatusProbe` reads. `make` is pure, so a test can
    /// check every case without a VM.
    struct Inputs: Sendable {
        var version: String
        var profile: String
        var selectedInApp: Bool
        var listing: Listing
        var action: String?
        var autoStart: Bool
        var autoStop: Bool
        var idleMinutes: Int
        /// The status of the running app, or nil if the app does not run.
        var app: AppStatus?
        /// The app runs but wrote no status file, for example a version
        /// before 0.10.0 that still runs after an upgrade.
        var appRunsWithoutFile = false
        var socketPath: String
        var socketKind: SocketKind
        var dockerContext: String?
        var now: Date
    }

    static func make(_ i: Inputs) -> CLIStatus {
        var vm = VM(state: .unknown, action: i.action)
        switch i.listing {
        case .notInstalled: vm.state = .notInstalled
        case .failed: vm.state = .unknown
        case .listed(nil): vm.state = .missing
        case .listed(let row?):
            switch row.status {
            case "Running": vm.state = .running
            case "Stopped": vm.state = .stopped
            case "Broken": vm.state = .broken
            default: vm.state = .unknown
            }
            vm.colimaStatus = row.status
            vm.runtime = row.runtime.flatMap { $0.isEmpty ? nil : $0 }
            vm.arch = row.arch.flatMap { $0.isEmpty ? nil : $0 }
            vm.cpus = row.cpus
            vm.memoryGiB = row.memoryGiB
            vm.diskGiB = row.diskGiB
        }
        // The stop time comes from the app. Without the app, nothing stops the VM.
        let stopsAt = i.autoStop ? i.app?.autoStopAt[i.profile] : nil
        let left = stopsAt.map { max(0, Int((($0.timeIntervalSince(i.now)) / 60).rounded(.up))) }
        return CLIStatus(
            version: i.version, profile: i.profile, selectedInApp: i.selectedInApp, vm: vm, autoStart: i.autoStart,
            autoStop: AutoStop(enabled: i.autoStop, idleMinutes: i.idleMinutes, stopsAt: stopsAt, minutesLeft: left),
            socket: Socket(path: i.socketPath, kind: i.socketKind), dockerContext: i.dockerContext,
            app: App(running: i.app != nil || i.appRunsWithoutFile, version: i.app?.version))
    }

    // MARK: - JSON

    /// The JSON text, with sorted keys and two spaces. Dates are ISO 8601 in UTC.
    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // The encoder cannot fail for these types.
        return (try? encoder.encode(Wire(self))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The wire form. The hand-written `encode(to:)` keeps each key when its value is nil.
    private struct Wire: Encodable {
        let s: CLIStatus
        init(_ s: CLIStatus) { self.s = s }

        enum Keys: String, CodingKey {
            case schemaVersion, version, profile, selectedInApp, vm, autoStart, autoStop, socket, dockerContext, app
        }
        enum VMKeys: String, CodingKey {
            case state, colimaStatus, action, runtime, arch, cpus, memoryGiB, diskGiB
        }
        enum AutoStopKeys: String, CodingKey { case enabled, idleMinutes, stopsAt, minutesLeft }
        enum SocketKeys: String, CodingKey { case path, kind }
        enum AppKeys: String, CodingKey { case running, version }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(CLIStatus.schemaVersion, forKey: .schemaVersion)
            try c.encode(s.version, forKey: .version)
            try c.encode(s.profile, forKey: .profile)
            try c.encode(s.selectedInApp, forKey: .selectedInApp)
            var vm = c.nestedContainer(keyedBy: VMKeys.self, forKey: .vm)
            try vm.encode(s.vm.state.rawValue, forKey: .state)
            try vm.encode(s.vm.colimaStatus, forKey: .colimaStatus)
            try vm.encode(s.vm.action, forKey: .action)
            try vm.encode(s.vm.runtime, forKey: .runtime)
            try vm.encode(s.vm.arch, forKey: .arch)
            try vm.encode(s.vm.cpus, forKey: .cpus)
            try vm.encode(s.vm.memoryGiB, forKey: .memoryGiB)
            try vm.encode(s.vm.diskGiB, forKey: .diskGiB)
            try c.encode(s.autoStart, forKey: .autoStart)
            var stop = c.nestedContainer(keyedBy: AutoStopKeys.self, forKey: .autoStop)
            try stop.encode(s.autoStop.enabled, forKey: .enabled)
            try stop.encode(s.autoStop.idleMinutes, forKey: .idleMinutes)
            try stop.encode(s.autoStop.stopsAt, forKey: .stopsAt)
            try stop.encode(s.autoStop.minutesLeft, forKey: .minutesLeft)
            var socket = c.nestedContainer(keyedBy: SocketKeys.self, forKey: .socket)
            try socket.encode(s.socket.path, forKey: .path)
            try socket.encode(s.socket.kind.rawValue, forKey: .kind)
            try c.encode(s.dockerContext, forKey: .dockerContext)
            var app = c.nestedContainer(keyedBy: AppKeys.self, forKey: .app)
            try app.encode(s.app.running, forKey: .running)
            try app.encode(s.app.version, forKey: .version)
        }
    }

    // MARK: - Text

    /// The text for a person. It shows `home` as `~` and the time in `timeZone`.
    func text(home: String, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            lines.append("\(label.padding(toLength: 12, withPad: " ", startingAt: 0))\(value)")
        }
        add("Profile:", profile + (selectedInApp ? " (shown in ColimaBar)" : ""))
        add("VM:", vmText)
        add("Action:", vm.action ?? "none")
        add("Auto-start:", autoStart ? "on" : "off")
        add("Auto-stop:", autoStopText(timeZone: timeZone))
        add("Socket:", "\(socket.path) (\(socket.kind.rawValue))")
        add("Context:", dockerContext ?? "unknown")
        add("ColimaBar:", app.running ? "running" + (app.version.map { ", version \($0)" } ?? "") : "not running")
        return HomeMask.apply(lines.joined(separator: "\n"), home: home)
    }

    private var vmText: String {
        switch vm.state {
        case .notInstalled: return "Colima is not installed"
        case .unknown: return "unknown (colima list gave no answer)"
        case .missing: return "the profile does not exist"
        default: break
        }
        var parts: [String] = []
        if let r = vm.runtime { parts.append(r) }
        if let a = vm.arch { parts.append(a) }
        if let c = vm.cpus { parts.append("\(c) CPUs") }
        if let m = vm.memoryGiB { parts.append("\(ByteFormat.gibText(m)) GiB memory") }
        if let d = vm.diskGiB { parts.append("\(d) GiB disk") }
        let name = vm.state.rawValue
        return parts.isEmpty ? name : "\(name) (\(parts.joined(separator: ", ")))"
    }

    private func autoStopText(timeZone: TimeZone) -> String {
        guard autoStop.enabled else { return "off" }
        var text = "on, after \(autoStop.idleMinutes) min idle"
        if let at = autoStop.stopsAt, let left = autoStop.minutesLeft {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "HH:mm"
            text += ", stops at \(f.string(from: at)) (in \(left) min)"
        }
        return text
    }
}
