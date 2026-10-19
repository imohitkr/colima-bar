import Foundation

@testable import ColimaBar

/// Doctor inputs for a healthy setup. A test changes the one part that it checks.
enum DoctorFixture {
    static let home = "/Users/me"
    static let stableHost = "unix:///Users/me/.cache/colima-bar/docker.sock"

    static func healthy() -> DoctorInputs {
        var i = DoctorInputs()
        i.profile = "default"
        i.home = home
        i.autoStart = true
        i.stableHost = stableHost
        i.tools = .init(
            colimaPath: "/opt/homebrew/bin/colima", limactlPath: "/opt/homebrew/bin/limactl",
            dockerPath: "/opt/homebrew/bin/docker",
            versions: ToolVersions(colima: "0.10.3", lima: "2.2.1", docker: "29.0.1", macOS: "15.6.1"))
        i.lastGoodVersions = ToolVersions(colima: "0.10.3", lima: "2.2.1", macOS: "15.6.1")
        i.context = .init(current: "colimabar", existing: ["default", "colimabar"])
        i.routes = .init(launchdHost: stableHost, testcontainersHost: stableHost)
        i.shell = .init(name: "zsh", found: nil)
        i.credentials = .init(config: DockerConfig(), available: ["osxkeychain"])
        i.plugins = ["docker-buildx", "docker-compose"].map {
            .init(
                name: $0,
                entries: [.init(folder: "\(home)/.docker/cli-plugins", state: .works, searchedByDocker: true)])
        }
        i.vm = .init(selected: row("default", "Running"), others: [row("default", "Running")])
        i.staleFiles = []
        i.disk = .init(
            vm: .init(usedKB: 10_000_000, availKB: 90_000_000), macFreeBytes: 100 * DiskSpace.gigabyte)
        i.ports = .checked(PortHealth.Report(okPorts: [8080]))
        i.dns = .checked(DNSHealth.Report(verdict: .ok))
        return i
    }

    static func row(_ name: String, _ status: String) -> ProfileRow {
        ProfileRow(name: name, isRunning: status == "Running", cpus: 2, memGB: 2, runtime: "docker", status: status)
    }
}
