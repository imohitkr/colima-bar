import Foundation
import Testing

@testable import ColimaBar

@Suite struct CrashReportDigestTests {
    private func report(app: String = "ColimaBar", extra: String = "") -> String {
        let header =
            #"{"app_name":"\#(app)","app_version":"0.9.0","build_version":"9","os_version":"macOS 26.0","timestamp":"2026-10-01 10:00:00.00 +0200","bug_type":"309","incident_id":"ABC","crashReporterKey":"SECRETKEY"}"#
        let body =
            #"{"captureTime":"2026-10-01 10:00:00","osVersion":{"train":"macOS 26.0"},"modelCode":"Mac15,3","cpuType":"ARM-64","procName":"ColimaBar","procPath":"\#(extra)/ColimaBar","exception":{"type":"EXC_CRASH"},"termination":{"namespace":"SIGNAL"},"faultingThread":0,"threads":[{"id":1}],"usedImages":[{"name":"a"}],"crashReporterKey":"SECRETKEY","sleepWakeUUID":"UUID1","bootSessionUUID":"UUID2","userID":501,"codeSigningID":"com.x","incident":"I1"}"#
        return header + "\n" + body
    }

    @Test func keepsTheAllowedKeysAndDropsTheRest() throws {
        let out = try #require(CrashReportDigest.reduce(report()))
        for kept in [
            "app_name: ColimaBar", "app_version: 0.9.0", "procName: ColimaBar", "faultingThread: 0",
            "modelCode: Mac15,3",
        ] {
            #expect(out.contains(kept), "\(kept)")
        }
        #expect(out.contains(#"exception: {"type":"EXC_CRASH"}"#))
        for dropped in [
            "SECRETKEY", "UUID1", "UUID2", "userID", "codeSigning", "incident", "crashReporterKey", "sleepWake",
        ] {
            #expect(!out.contains(dropped), "\(dropped)")
        }
    }

    @Test func refusesAReportOfAnotherApp() {
        #expect(CrashReportDigest.reduce(report(app: "Safari")) == nil)
    }

    @Test func badJSONGivesNil() {
        #expect(CrashReportDigest.reduce("not json") == nil)
        #expect(CrashReportDigest.reduce("{\"app_name\":\"ColimaBar\"}\nnot json") == nil)
        #expect(CrashReportDigest.reduce("") == nil)
    }

    @Test func aDigestHasALimit() throws {
        let big = String(repeating: "x", count: 400_000)
        let text = report(extra: big)
        let out = try #require(CrashReportDigest.reduce(text))
        #expect(out.utf8.count <= CrashReportDigest.maxBytes + 64)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func now() -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))! }

    @Test func pickGivesTheNewestFirst() {
        let names = [
            "ColimaBar-2026-10-01-100000.ips", "ColimaBar-2026-10-10-090000.ips", "ColimaBar-2026-10-10-180000.ips",
        ]
        #expect(
            CrashReportDigest.pick(names: names, now: now(), calendar: calendar) == [
                "ColimaBar-2026-10-10-180000.ips", "ColimaBar-2026-10-10-090000.ips", "ColimaBar-2026-10-01-100000.ips",
            ])
    }

    @Test func pickKeepsOnlyTheLast30DaysOfColimaBar() {
        let names = [
            "ColimaBar-2026-09-16-120000.ips", "ColimaBar-2026-09-17-130000.ips", "Safari-2026-10-10-090000.ips",
            "ColimaBar-2026-10-10-090000.txt", "ColimaBar-bad.ips",
        ]
        #expect(
            CrashReportDigest.pick(names: names, now: now(), calendar: calendar) == ["ColimaBar-2026-09-17-130000.ips"])
    }

    @Test func pickGivesAtMostTenNames() {
        let names = (1...15).map { String(format: "ColimaBar-2026-10-%02d-100000.ips", $0) }
        let picked = CrashReportDigest.pick(names: names, now: now(), calendar: calendar)
        #expect(picked.count == 10)
        #expect(picked.first == "ColimaBar-2026-10-15-100000.ips")
    }

    @Test func aPathInTheReportComesOutWithoutEscapedSlashesSoTheRedactorHidesIt() throws {
        let header = #"{"app_name":"ColimaBar","app_version":"0.9.0"}"#
        let body = #"{"usedImages":[{"path":"/Users/jd/Library/app.dylib"}]}"#
        let out = try #require(CrashReportDigest.reduce(header + "\n" + body))
        #expect(out.contains("/Users/jd/Library/app.dylib"))
        #expect(!out.contains(#"\/"#))
        let hidden = Redactor(home: "/Users/someone-else").redact(out)
        #expect(!hidden.contains("jd"), "\(hidden)")
        #expect(hidden.contains("/Users/<user>/Library/app.dylib"))
    }
}
