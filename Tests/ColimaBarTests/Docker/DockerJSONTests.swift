import Foundation
import Testing

@testable import ColimaBar

@Suite struct DockerJSONTests {
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

    @Test func inspectReadsAutoRemoveAndTty() throws {
        let json = """
            {"Id":"abc","Config":{"Tty":true,"Image":"alpine"},"HostConfig":{"AutoRemove":true,"NetworkMode":"bridge"}}
            """
        let i = try JSONDecoder().decode(APIInspect.self, from: Data(json.utf8))
        #expect(i.HostConfig?.AutoRemove == true)
        #expect(i.Config?.Tty == true)
        let plain = try JSONDecoder().decode(APIInspect.self, from: Data(#"{"Id":"abc"}"#.utf8))
        #expect(plain.HostConfig?.AutoRemove == nil)
    }
}
