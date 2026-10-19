import Foundation
import Testing

@testable import ColimaBar

@Suite struct CLIStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z

    private let runningRow = CLIStatus.Row(
        status: "Running", runtime: "docker", arch: "aarch64", cpus: 4, memoryGiB: 8, diskGiB: 100)

    private func inputs(
        listing: CLIStatus.Listing? = nil, action: String? = nil, autoStop: Bool = true, app: AppStatus? = nil,
        kind: CLIStatus.SocketKind = .proxy, context: String? = "colimabar", selected: Bool = true
    ) -> CLIStatus.Inputs {
        CLIStatus.Inputs(
            version: "0.10.0", profile: "default", selectedInApp: selected, listing: listing ?? .listed(runningRow),
            action: action, autoStart: true, autoStop: autoStop, idleMinutes: 30, app: app,
            socketPath: "/Users/me/.cache/colima-bar/docker.sock", socketKind: kind, dockerContext: context, now: now)
    }

    private func app(stopsIn seconds: TimeInterval?) -> AppStatus {
        AppStatus(
            pid: 42, version: "0.10.0",
            autoStopAt: seconds.map { ["default": now.addingTimeInterval($0)] } ?? [:])
    }

    private func make(_ i: CLIStatus.Inputs) -> CLIStatus { CLIStatus.make(i) }

    // MARK: - JSON

    @Test func theJSONOfARunningVMIsTheContract() {
        let json = make(inputs(app: app(stopsIn: 12 * 60))).json()
        #expect(
            json == """
                {
                  "app" : {
                    "running" : true,
                    "version" : "0.10.0"
                  },
                  "autoStart" : true,
                  "autoStop" : {
                    "enabled" : true,
                    "idleMinutes" : 30,
                    "minutesLeft" : 12,
                    "stopsAt" : "2027-01-15T08:12:00Z"
                  },
                  "dockerContext" : "colimabar",
                  "profile" : "default",
                  "schemaVersion" : 1,
                  "selectedInApp" : true,
                  "socket" : {
                    "kind" : "proxy",
                    "path" : "/Users/me/.cache/colima-bar/docker.sock"
                  },
                  "version" : "0.10.0",
                  "vm" : {
                    "action" : null,
                    "arch" : "aarch64",
                    "colimaStatus" : "Running",
                    "cpus" : 4,
                    "diskGiB" : 100,
                    "memoryGiB" : 8,
                    "runtime" : "docker",
                    "state" : "running"
                  }
                }
                """)
    }

    @Test func everyKeyIsThereWhenTheValuesAreMissing() throws {
        let status = make(inputs(listing: .notInstalled, autoStop: false, kind: .missing, context: nil))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(status.json().utf8)) as? [String: Any])
        let vm = try #require(object["vm"] as? [String: Any])
        for key in ["state", "colimaStatus", "action", "runtime", "arch", "cpus", "memoryGiB", "diskGiB"] {
            #expect(vm[key] != nil, "vm.\(key) is missing")
        }
        #expect(vm["state"] as? String == "notInstalled")
        #expect(vm["colimaStatus"] is NSNull && vm["cpus"] is NSNull)
        let stop = try #require(object["autoStop"] as? [String: Any])
        #expect(stop["stopsAt"] is NSNull && stop["minutesLeft"] is NSNull)
        #expect(object["dockerContext"] is NSNull)
        let app = try #require(object["app"] as? [String: Any])
        #expect(app["running"] as? Bool == false && app["version"] is NSNull)
    }

    @Test func aPathKeepsItsSlashes() {
        #expect(make(inputs()).json().contains("\"/Users/me/.cache/colima-bar/docker.sock\""))
    }

    @Test func aFractionOfMemoryStaysInTheJSON() {
        var row = runningRow
        row.memoryGiB = 2.5
        #expect(make(inputs(listing: .listed(row))).json().contains("\"memoryGiB\" : 2.5"))
    }

    // MARK: - The VM

    @Test func theStateComesFromColima() {
        func state(_ listing: CLIStatus.Listing) -> CLIStatus.State { make(inputs(listing: listing)).vm.state }
        func row(_ status: String) -> CLIStatus.Listing {
            .listed(CLIStatus.Row(status: status, runtime: "docker"))
        }
        #expect(state(row("Running")) == .running)
        #expect(state(row("Stopped")) == .stopped)
        #expect(state(row("Broken")) == .broken)
        #expect(state(row("Starting")) == .unknown)
        #expect(state(.listed(nil)) == .missing)
        #expect(state(.notInstalled) == .notInstalled)
        #expect(state(.failed) == .unknown)
    }

    @Test func theColimaStatusIsKeptWhenTheStateIsUnknown() {
        let status = make(inputs(listing: .listed(CLIStatus.Row(status: "Starting"))))
        #expect(status.vm.colimaStatus == "Starting")
        #expect(status.vm.runtime == nil && status.vm.cpus == nil)
    }

    @Test func anEmptyRuntimeIsNoRuntime() {
        let status = make(inputs(listing: .listed(CLIStatus.Row(status: "Stopped", runtime: "", arch: ""))))
        #expect(status.vm.runtime == nil && status.vm.arch == nil)
    }

    @Test func theActionComesFromTheBusyMarker() {
        #expect(make(inputs(action: "Starting")).vm.action == "Starting")
        #expect(make(inputs()).vm.action == nil)
    }

    // MARK: - Auto-stop

    @Test func theTimeLeftRoundsUpToWholeMinutes() {
        func left(_ seconds: TimeInterval) -> Int? { make(inputs(app: app(stopsIn: seconds))).autoStop.minutesLeft }
        #expect(left(12 * 60) == 12)
        #expect(left(11 * 60 + 1) == 12)
        #expect(left(11 * 60 + 59) == 12)
        #expect(left(1) == 1)
        #expect(left(0) == 0)
        #expect(left(-30) == 0)  // the stop is due now
    }

    @Test func anAppWithoutAStatusFileRunsWithNoVersionAndNoStopTime() {
        var i = inputs(app: nil)
        i.appRunsWithoutFile = true
        let status = make(i)
        #expect(status.app.running)
        #expect(status.app.version == nil)
        #expect(status.autoStop.stopsAt == nil)
        #expect(!make(inputs(app: nil)).app.running)
    }

    @Test func noStopTimeWithoutTheAppOrWithAutoStopOff() {
        #expect(make(inputs(app: nil)).autoStop.stopsAt == nil)
        #expect(make(inputs(autoStop: false, app: app(stopsIn: 600))).autoStop.stopsAt == nil)
        #expect(make(inputs(app: app(stopsIn: nil))).autoStop.stopsAt == nil)
        // The app lists only other profiles.
        let other = AppStatus(pid: 1, version: "x", autoStopAt: ["work": now.addingTimeInterval(60)])
        #expect(make(inputs(app: other)).autoStop.stopsAt == nil)
    }

    // MARK: - Text

    @Test func theTextOfARunningVM() {
        let text = make(inputs(app: app(stopsIn: 12 * 60))).text(
            home: "/Users/me", timeZone: TimeZone(identifier: "UTC")!)
        #expect(
            text == """
                Profile:    default (shown in ColimaBar)
                VM:         running (docker, aarch64, 4 CPUs, 8 GiB memory, 100 GiB disk)
                Action:     none
                Auto-start: on
                Auto-stop:  on, after 30 min idle, stops at 08:12 (in 12 min)
                Socket:     ~/.cache/colima-bar/docker.sock (proxy)
                Context:    colimabar
                ColimaBar:  running, version 0.10.0
                """)
    }

    @Test func theTextOfAStoppedVMWithoutTheApp() {
        let row = CLIStatus.Row(status: "Stopped", runtime: "docker", arch: "aarch64", cpus: 2, memoryGiB: 2.5)
        let text = make(inputs(listing: .listed(row), autoStop: false, kind: .link, selected: false)).text(
            home: "/Users/me")
        #expect(text.contains("Profile:    default\n"))
        #expect(text.contains("VM:         stopped (docker, aarch64, 2 CPUs, 2.5 GiB memory)"))
        #expect(text.contains("Auto-stop:  off"))
        #expect(text.contains("(link)"))
        #expect(text.contains("ColimaBar:  not running"))
    }

    @Test func theTextOfABusyVM() {
        #expect(make(inputs(action: "Starting")).text(home: "/Users/me").contains("Action:     Starting"))
    }

    @Test func theTextOfAMissingProfile() {
        let text = make(inputs(listing: .listed(nil))).text(home: "/Users/me")
        #expect(text.contains("VM:         the profile does not exist"))
    }

    @Test func theTextWhenColimaIsNotInstalled() {
        #expect(
            make(inputs(listing: .notInstalled)).text(home: "/Users/me").contains("VM:         Colima is not installed")
        )
    }

    @Test func theTextWhenColimaGivesNoList() {
        let text = make(inputs(listing: .failed, context: nil)).text(home: "/Users/me")
        #expect(text.contains("VM:         unknown (colima list gave no answer)"))
        #expect(text.contains("Context:    unknown"))
    }
}
