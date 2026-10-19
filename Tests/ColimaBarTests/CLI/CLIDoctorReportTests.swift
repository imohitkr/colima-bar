import Foundation
import Testing

@testable import ColimaBar

@Suite struct CLIDoctorReportTests {
    private let results: [DoctorResult] = [
        .init(.tools, .ok, "colima 0.10.3"),
        .init(.context, .warning, "The current context is default.", fix: .useColimabar),
        .init(
            .credentials, .warning, "credHelpers names a missing helper for 123.dkr.ecr.eu-west-1.amazonaws.com.",
            shareDetail: "credHelpers names a missing helper for 1 registry."),
        .init(.shellHost, .problem, "/Users/me/.zshrc line 3 sets DOCKER_HOST"),
        .init(.diskSpace, .skipped, "The VM is stopped."),
    ]

    private func doctor() -> CLIDoctorReport {
        CLIDoctorReport(
            version: "0.10.0",
            report: DoctorReport(profile: "work", date: Date(timeIntervalSince1970: 0), results: results),
            home: "/Users/me")
    }

    private func object() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(doctor().json().utf8)) as? [String: Any])
    }

    @Test func theJSONHasTheHeaderFields() throws {
        let o = try object()
        #expect(o["schemaVersion"] as? Int == 1)
        #expect(o["version"] as? String == "0.10.0")
        #expect(o["profile"] as? String == "work")
        #expect(o["problems"] as? Int == 1)
        #expect(o["warnings"] as? Int == 2)
    }

    @Test func eachCheckHasAllFiveKeysInTheOrderOfDoctor() throws {
        let checks = try #require(try object()["checks"] as? [[String: Any]])
        #expect(checks.map { $0["id"] as? String } == ["tools", "context", "credentials", "shellHost", "diskSpace"])
        #expect(
            checks.map { $0["status"] as? String } == ["ok", "warning", "warning", "problem", "skipped"])
        for c in checks { #expect(Set(c.keys) == ["id", "title", "status", "detail", "fix"]) }
        #expect(checks[1]["title"] as? String == "Docker context")
    }

    @Test func theNetworkChecksAreNewItemsAndTheSchemaStaysAtOne() throws {
        let report = DoctorReport(
            profile: "work", date: Date(timeIntervalSince1970: 0),
            results: [
                .init(.portForwarding, .problem, "Ports 8080 answer in the VM but not on the Mac.", fix: .restartVM),
                .init(.vmDNS, .ok, "The VM resolves registry-1.docker.io."),
            ])
        let json = CLIDoctorReport(version: "0.10.0", report: report, home: "/Users/me").json()
        let o = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let checks = try #require(o["checks"] as? [[String: Any]])
        #expect(o["schemaVersion"] as? Int == 1)
        #expect(checks.map { $0["id"] as? String } == ["portForwarding", "vmDNS"])
        #expect(checks.map { $0["title"] as? String } == ["Port forwarding", "DNS in the VM"])
        #expect(checks[0]["fix"] as? String == "restartVM")
    }

    @Test func aFixIsItsNameAndNoFixIsNull() throws {
        let checks = try #require(try object()["checks"] as? [[String: Any]])
        #expect(checks[1]["fix"] as? String == "useColimabar")
        #expect(checks[0]["fix"] is NSNull)
    }

    @Test func noRegistryHostAndNoHomeFolderReachTheJSON() {
        let json = doctor().json()
        #expect(!json.contains("amazonaws") && json.contains("1 registry"))
        #expect(!json.contains("/Users/me") && json.contains("~/.zshrc line 3"))
    }

    @Test func noRegistryHostAndNoHomeFolderReachTheText() {
        let text = doctor().text()
        #expect(!text.contains("amazonaws") && !text.contains("/Users/me"))
        #expect(text.hasPrefix("ColimaBar 0.10.0, profile work, 1 problem, 2 warnings"))
        #expect(text.contains("[problem] Shell DOCKER_HOST: ~/.zshrc line 3 sets DOCKER_HOST"))
    }
}
