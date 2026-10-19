import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct CLIStatusProbeTests {
    // MARK: - Socket kinds

    @Test func aSocketIsTheProxyWhileTheAppRuns() async throws {
        let path = TestSocketPath.unique()
        // The kind needs only a socket file. A bound socket without a listener is enough.
        let fd = try UnixSocket.listen(path)
        defer {
            close(fd)
            unlink(path)
        }
        #expect(CLIStatusProbe.socketKind(path: path, appRunning: true) == .proxy)
    }

    @Test func aSocketWithoutTheAppIsStale() async throws {
        let path = TestSocketPath.unique()
        // The kind needs only a socket file. A bound socket without a listener is enough.
        let fd = try UnixSocket.listen(path)
        defer {
            close(fd)
            unlink(path)
        }
        #expect(CLIStatusProbe.socketKind(path: path, appRunning: false) == .stale)
    }

    @Test func aSocketAtAPathThatNoProxyOwnsIsOther() async throws {
        let path = TestSocketPath.unique()
        // The kind needs only a socket file. A bound socket without a listener is enough.
        let fd = try UnixSocket.listen(path)
        defer {
            close(fd)
            unlink(path)
        }
        #expect(CLIStatusProbe.socketKind(path: path, appRunning: true, isProxyPath: false) == .other)
    }

    @Test func aLinkIsALinkAlsoWhenItPointsNowhere() {
        let path = TestSocketPath.unique()
        symlink("/nonexistent/docker.sock", path)
        defer { unlink(path) }
        #expect(CLIStatusProbe.socketKind(path: path, appRunning: true) == .link)
    }

    @Test func noFileIsMissing() {
        #expect(CLIStatusProbe.socketKind(path: TestSocketPath.unique(), appRunning: true) == .missing)
    }

    @Test func aPlainFileIsOther() throws {
        let tmp = try TempFolder()
        FileManager.default.createFile(atPath: "\(tmp.path)/docker.sock", contents: nil)
        #expect(CLIStatusProbe.socketKind(path: "\(tmp.path)/docker.sock", appRunning: true) == .other)
    }

    // MARK: - The busy marker

    private func marker(_ tmp: TempFolder, _ text: String, age: TimeInterval = 0) throws -> String {
        let path = "\(tmp.path)/busy.default"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: path)
        return path
    }

    @Test func theBusyLabelIsTheFirstLineWhileTheOwnerRuns() throws {
        let tmp = try TempFolder()
        let path = try marker(tmp, "Starting\n4242\n", age: 60)
        let started = Date(timeIntervalSinceNow: -3600)
        #expect(CLIStatusProbe.busyLabel(profile: "default", path: path, startTime: { _ in started }) == "Starting")
    }

    @Test func aMarkerWhoseOwnerIsGoneCountsAsNoActionAndStays() throws {
        let tmp = try TempFolder()
        let path = try marker(tmp, "Starting\n4242\n", age: 60)
        #expect(CLIStatusProbe.busyLabel(profile: "default", path: path, startTime: { _ in nil }) == nil)
        #expect(FileManager.default.fileExists(atPath: path))  // the command removes no file of the app
    }

    @Test func aMarkerWhosePIDWasTakenByANewerProcessIsStale() throws {
        let tmp = try TempFolder()
        let path = try marker(tmp, "Stopping\n4242\n", age: 600)
        let started = Date(timeIntervalSinceNow: -10)  // after the marker was written
        #expect(CLIStatusProbe.busyLabel(profile: "default", path: path, startTime: { _ in started }) == nil)
    }

    @Test func anOldMarkerWithoutAPIDExpiresByAge() throws {
        let tmp = try TempFolder()
        let fresh = try marker(tmp, "Restarting\n", age: 60)
        #expect(CLIStatusProbe.busyLabel(profile: "default", path: fresh, startTime: { _ in nil }) == "Restarting")
        let old = try marker(tmp, "Restarting\n", age: BusyMarker.maxAgeWithoutPID + 60)
        #expect(CLIStatusProbe.busyLabel(profile: "default", path: old, startTime: { _ in nil }) == nil)
    }

    @Test func noMarkerMeansNoAction() throws {
        let tmp = try TempFolder()
        #expect(CLIStatusProbe.busyLabel(profile: "default", path: "\(tmp.path)/none") == nil)
    }

    // MARK: - The list of Colima

    @Test func theRowsOfColimaListAreRead() {
        let output = """
            {"name":"default","status":"Running","arch":"aarch64","cpus":4,"memory":8589934592,"disk":107374182400,"runtime":"docker"}
            {"name":"work","status":"Stopped","arch":"aarch64","cpus":2,"memory":2899102924,"disk":64424509440,"runtime":"containerd"}
            not json
            """
        let rows = CLIStatusProbe.rows(from: output)
        #expect(rows.keys.sorted() == ["default", "work"])
        #expect(
            rows["default"]
                == CLIStatus.Row(
                    status: "Running", runtime: "docker", arch: "aarch64", cpus: 4, memoryGiB: 8, diskGiB: 100))
        #expect(rows["work"]?.memoryGiB == 2.7)
        #expect(rows["work"]?.runtime == "containerd")
    }

    @Test func aRowWithoutANameIsTheDefaultProfile() {
        #expect(CLIStatusProbe.rows(from: #"{"status":"Stopped"}"#).keys.sorted() == ["default"])
    }

    @Test func outputWithoutAReadableLineIsAFailedList() {
        #expect(CLIStatusProbe.list(from: "colima: unexpected format\n") == .failed)
        #expect(CLIStatusProbe.list(from: "{not json}") == .failed)
    }

    @Test func oneObjectALineWithTrailingNewlinesIsAList() {
        let output = "{\"name\":\"a\",\"status\":\"Running\"}\n{\"name\":\"b\",\"status\":\"Stopped\"}\n\n"
        guard case .listed(let rows) = CLIStatusProbe.list(from: output) else {
            Issue.record("expected a list")
            return
        }
        #expect(rows.keys.sorted() == ["a", "b"])
    }

    @Test func emptyOutputIsAListWithoutProfiles() {
        #expect(CLIStatusProbe.list(from: "") == .listed([:]))
        #expect(CLIStatusProbe.list(from: "\n  \n") == .listed([:]))
    }

    @Test func aReadableLineMakesAList() {
        guard case .listed(let rows) = CLIStatusProbe.list(from: #"{"name":"a","status":"Running"}"#) else {
            Issue.record("expected a list")
            return
        }
        #expect(rows.keys.sorted() == ["a"])
    }

    @Test func noRowsForAnEmptyList() {
        #expect(CLIStatusProbe.rows(from: "").isEmpty)
    }
}
