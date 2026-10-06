import Foundation
import Testing
@testable import ColimaBar

@Suite struct ParsingTests {
    @Test func yamlTopLevelAndSection() {
        let yaml = """
        cpu: 4
        rosetta: true
        kubernetes:
          # Enable kubernetes.
          enabled: false
          version: v1.30
        network:
          enabled: true
        """
        #expect(Parse.yaml(yaml, key: "cpu") == "4")
        #expect(Parse.yaml(yaml, key: "rosetta") == "true")
        #expect(Parse.yaml(yaml, key: "enabled", section: "kubernetes") == "false")
        #expect(Parse.yaml(yaml, key: "enabled", section: "network") == "true")
        #expect(Parse.yaml(yaml, key: "missing") == nil)
    }

    @Test func statsMatchDockerFormulas() throws {
        let json = """
        {"cpu_stats":{"cpu_usage":{"total_usage":3000000000},"system_cpu_usage":20000000000,"online_cpus":4},
         "precpu_stats":{"cpu_usage":{"total_usage":1000000000},"system_cpu_usage":10000000000},
         "memory_stats":{"usage":104857600,"stats":{"inactive_file":4857600}}}
        """
        let s = try JSONDecoder().decode(APIStats.self, from: Data(json.utf8))
        // (2e9 / 1e10) * 4 cores * 100 = 80% of one core
        #expect(abs(s.cpuPercent - 80) < 0.001)
        #expect(s.memBytes == 100_000_000)
    }

    @Test func statsWithNoPreviousSampleIsZero() throws {
        let json = """
        {"cpu_stats":{"cpu_usage":{"total_usage":5},"system_cpu_usage":10,"online_cpus":2},
         "precpu_stats":{"cpu_usage":{"total_usage":0}},
         "memory_stats":{}}
        """
        let s = try JSONDecoder().decode(APIStats.self, from: Data(json.utf8))
        #expect(s.cpuPercent == 0)
        #expect(s.memBytes == 0)
    }

    @Test func containerHealth() {
        func c(_ status: String) -> Container {
            Container(id: "x", name: "x", image: "i", state: "running", status: status, ports: [], project: nil)
        }
        #expect(c("Up 2 hours (healthy)").health == "healthy")
        #expect(c("Up 5 seconds (health: starting)").health == "health: starting")
        #expect(c("Up 1 minute (unhealthy)").health == "unhealthy")
        #expect(c("Up 3 days").health == nil)
    }

    @Test func containerDecodesFromAPI() throws {
        let json = """
        [{"Id":"abc123","Names":["/web"],"Image":"nginx","State":"running","Status":"Up 1 minute",
          "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"PrivatePort":443,"Type":"tcp"}],
          "Labels":{"com.docker.compose.project":"shop"}}]
        """
        let list = try JSONDecoder().decode([APIContainer].self, from: Data(json.utf8))
        #expect(list.first?.Names == ["/web"])
        #expect(list.first?.Ports?.compactMap { $0.IP != nil ? $0.PublicPort : nil } == [8080])
        #expect(list.first?.Labels?["com.docker.compose.project"] == "shop")
    }

    @Test func formatsBytes() {
        #expect(Fmt.bytes(0) == "0 B")
        #expect(Fmt.bytes(512) == "512 B")
        #expect(Fmt.bytes(1536) == "1.5 KB")
        #expect(Fmt.bytes(5 * 1024 * 1024 * 1024) == "5.0 GB")
        #expect(Fmt.bytes(250 * 1024 * 1024) == "250 MB")
    }

    @Test func dechunk() {
        let body = Data("4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n".utf8)
        #expect(String(decoding: DockerAPI.dechunk(body), as: UTF8.self) == "Wikipedia")
    }

    @Test func kubeContextNames() {
        #expect(Paths.kubeContext("default") == "colima")
        #expect(Paths.kubeContext("work") == "colima-work")
        #expect(Paths.socket("work").hasSuffix("/.config/colima/work/docker.sock"))
    }
}

@Suite struct LogTests {
    private func frame(_ stream: UInt8, _ s: String) -> Data {
        let payload = Data(s.utf8)
        let n = UInt32(payload.count)
        return Data([stream, 0, 0, 0, UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) + payload
    }

    @Test func demuxesStdoutAndStderrFrames() {
        var d = LogDemuxer(tty: false)
        let lines = d.feed(frame(1, "hello\nwor") + frame(2, "oops\n") + frame(1, "ld\n"))
        #expect(lines.map(\.0) == ["hello", "oops", "world"])
        #expect(lines.map(\.1) == [false, true, false])
    }

    @Test func demuxHandlesFramesSplitAcrossReads() {
        var d = LogDemuxer(tty: false)
        let all = frame(1, "split line\n")
        #expect(d.feed(all.prefix(5)).isEmpty)
        #expect(d.feed(all.dropFirst(5).prefix(4)).isEmpty)
        #expect(d.feed(all.dropFirst(9)).map(\.0) == ["split line"])
    }

    @Test func ttyLogsAreRawText() {
        var d = LogDemuxer(tty: true)
        #expect(d.feed(Data("a\r\nb\n".utf8)).map(\.0) == ["a", "b"])
    }

    @Test @MainActor func clockTrimsNanoseconds() {
        let t = LogStore.clock("2026-10-02T14:03:11.123456789Z")
        #expect(t.count == 12)          // HH:mm:ss.SSS in local time
        #expect(t.hasSuffix("11.123"))
        #expect(LogStore.clock("garbage") == "")
    }
}

@Suite struct LogSinceTests {
    @Test @MainActor func convertsRFC3339ToUnixNanosPlusOne() {
        #expect(LogStore.sinceParam("1970-01-01T00:00:10.000000005Z") == "10.000000006")
        #expect(LogStore.sinceParam("1970-01-01T00:00:10.5Z") == "10.500000001")
    }

    @Test @MainActor func carriesIntoSeconds() {
        #expect(LogStore.sinceParam("1970-01-01T00:00:10.999999999Z") == "11.000000000")
    }

    @Test @MainActor func handlesMissingFraction() {
        #expect(LogStore.sinceParam("1970-01-01T00:01:00Z") == "60.000000001")
    }

    @Test @MainActor func rejectsGarbage() {
        #expect(LogStore.sinceParam("nope") == nil)
    }
}
