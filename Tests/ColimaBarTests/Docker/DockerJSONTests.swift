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

    @Test func infoDecodesTheVMClock() throws {
        let json = #"{"ID":"x","SystemTime":"2026-10-15T19:54:38.123456789+02:00","Containers":3}"#
        let info = try JSONDecoder().decode(APIInfo.self, from: Data(json.utf8))
        #expect(info.SystemTime == "2026-10-15T19:54:38.123456789+02:00")
        let none = try JSONDecoder().decode(APIInfo.self, from: Data("{}".utf8))
        #expect(none.SystemTime == nil)
    }

    @Test func infoDecodesTheArchitecture() throws {
        let info = try JSONDecoder().decode(APIInfo.self, from: Data(#"{"Architecture":"aarch64"}"#.utf8))
        #expect(info.Architecture == "aarch64")
    }

    @Test func volumeDecodesItsFacts() throws {
        let json =
            #"{"Name":"pg","Driver":"local","Labels":{"a":"b"},"CreatedAt":"2026-01-01T00:00:00Z","Mountpoint":"/x"}"#
        let v = try JSONDecoder().decode(APIVolume.self, from: Data(json.utf8))
        #expect(
            v.Name == "pg" && v.Driver == "local" && v.Labels == ["a": "b"] && v.CreatedAt == "2026-01-01T00:00:00Z")
        let bare = try JSONDecoder().decode(APIVolume.self, from: Data(#"{"Name":"x","Labels":null}"#.utf8))
        #expect(bare.Labels == nil && bare.Driver == nil)
    }

    @Test func createReplyGivesTheID() throws {
        let r = try JSONDecoder().decode(APIIdResponse.self, from: Data(#"{"Id":"abc","Warnings":[]}"#.utf8))
        #expect(r.Id == "abc")
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

    @Test func statusDecodesTheIPAddressOfTheVM() throws {
        let json = #"{"driver":"macOS Virtualization.Framework","mount_type":"virtiofs","ip_address":"192.168.64.3"}"#
        let st = try JSONDecoder().decode(ColimaStatusJSON.self, from: Data(json.utf8))
        #expect(st.ip_address == "192.168.64.3" && st.mount_type == "virtiofs")
        let none = try JSONDecoder().decode(ColimaStatusJSON.self, from: Data(#"{"driver":"x"}"#.utf8))
        #expect(none.ip_address == nil)
    }

    @Test func aPlainLocalVolumeCanBeReplaced() throws {
        func volume(_ json: String) throws -> APIVolume {
            try JSONDecoder().decode(APIVolume.self, from: Data(json.utf8))
        }
        #expect(try volume(#"{"Name":"a","Driver":"local","Options":null}"#).isPlain)
        #expect(try volume(#"{"Name":"a","Driver":"local","Options":{}}"#).isPlain)
        #expect(try volume(#"{"Name":"a"}"#).isPlain)
        #expect(try !volume(#"{"Name":"a","Driver":"local","Options":{"type":"nfs"}}"#).isPlain)
        #expect(try !volume(#"{"Name":"a","Driver":"other"}"#).isPlain)
    }

    @Test func systemDFDecodesTheCleanupFields() throws {
        let json = """
            {"Containers":[{"Id":"abc","Names":["/api"],"Image":"api:1","Labels":{"a":"b"},"SizeRw":5,"State":"exited"}],
             "BuildCache":[{"ID":"x1","Type":"regular","Description":"d","LastUsedAt":"2026-01-02T03:04:05Z",
                            "Size":9,"InUse":false,"Shared":true}]}
            """
        let df = try JSONDecoder().decode(APIDF.self, from: Data(json.utf8))
        let c = try #require(df.Containers?.first)
        #expect(c.Id == "abc" && c.Names == ["/api"] && c.Image == "api:1" && c.Labels == ["a": "b"])
        let k = try #require(df.BuildCache?.first)
        #expect(k.ID == "x1" && k.Type == "regular" && k.Description == "d")
        #expect(k.LastUsedAt == "2026-01-02T03:04:05Z")
    }

    @Test func systemDFDecodesWithoutThem() throws {
        let json =
            #"{"Containers":[{"SizeRw":5,"State":"exited"}],"BuildCache":[{"Size":9,"InUse":false,"Shared":false}]}"#
        let df = try JSONDecoder().decode(APIDF.self, from: Data(json.utf8))
        #expect(df.Containers?.first?.Id == nil)
        #expect(df.BuildCache?.first?.ID == nil)
    }
}
