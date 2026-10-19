import Foundation
import Testing

@testable import ColimaBar

@Suite struct ContainerDetailTests {
    private static let fixture = #"""
        {
          "Id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "Name": "/web-1",
          "Created": "2026-10-01T08:00:00.123456789Z",
          "Image": "sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777",
          "RestartCount": 3,
          "State": {
            "Status": "exited", "OOMKilled": true, "ExitCode": 137, "Error": "",
            "StartedAt": "2026-10-01T08:00:01.5Z", "FinishedAt": "0001-01-01T00:00:00Z",
            "Health": {
              "Status": "unhealthy", "FailingStreak": 4,
              "Log": [
                {"Start": "2026-10-01T08:00:10Z", "ExitCode": 0, "Output": "first"},
                {"Start": "2026-10-01T08:00:20Z", "ExitCode": 1, "Output": "second"},
                {"Start": "2026-10-01T08:00:30Z", "ExitCode": 1, "Output": "third"},
                {"Start": "2026-10-01T08:00:40Z", "ExitCode": 2, "Output": "line one\n  line   two\tLONGX"}
              ]
            }
          },
          "HostConfig": {
            "RestartPolicy": {"Name": "on-failure", "MaximumRetryCount": 5},
            "Privileged": true, "Memory": 0, "MemoryReservation": 268435456,
            "NanoCpus": 1500000000, "CpuShares": 0, "PidsLimit": null
          },
          "Config": {
            "Image": "nginx:alpine",
            "Env": ["PATH=/usr/bin", "API_TOKEN=abc", "URL=postgres://a:b@h/x", "NOVALUE"],
            "Cmd": ["nginx", "-g", "daemon off;"], "Entrypoint": null,
            "WorkingDir": "/app", "User": "",
            "Labels": {"b.label": "1", "com.docker.compose.service": "web", "a.label": "2",
                       "com.docker.compose.project": "demo", "db.password": "pw"}
          },
          "Mounts": [
            {"Type": "bind", "Source": "/Users/ab/docs", "Destination": "/docs", "RW": false},
            {"Type": "volume", "Name": "data", "Source": "/var/lib/docker/volumes/data/_data",
             "Destination": "/data", "RW": true}
          ],
          "NetworkSettings": {
            "Networks": {
              "zeta": {"IPAddress": "172.20.0.2", "GlobalIPv6Address": "", "Aliases": ["web", "0123456789ab"],
                       "DNSNames": ["web", "web-1", "0123456789ab"]},
              "alpha": {"IPAddress": "172.19.0.2", "GlobalIPv6Address": "fd00::2", "Aliases": null, "DNSNames": null}
            },
            "Ports": {
              "80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "18080"}, {"HostIp": "::", "HostPort": "18080"}],
              "53/udp": [{"HostIp": "127.0.0.1", "HostPort": "5353"}],
              "9000/tcp": null
            }
          }
        }
        """#

    private func make(digests: [String] = []) throws -> ContainerDetail {
        let json = Self.fixture.replacingOccurrences(of: "LONGX", with: String(repeating: "x", count: 300))
        let api = try JSONDecoder().decode(APIContainerDetail.self, from: Data(json.utf8))
        return ContainerDetail.make(from: api, digests: digests)
    }

    @Test func aPortOnAllAddressesShowsOnce() throws {
        let json =
            #"{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"18080"},{"HostIp":"::","HostPort":"18080"}],"#
            + #""6379/tcp":[{"HostIp":"127.0.0.1","HostPort":"16379"},{"HostIp":"::1","HostPort":"16379"}]}"#
        let all = try JSONDecoder().decode(
            [String: [APIContainerDetail.Binding]?].self, from: Data(json.utf8))
        let rows = ContainerDetail.ports(all)
        #expect(rows.filter { $0.hostPort == 18080 }.count == 1)
        // Loopback bindings are two different addresses: both stay.
        #expect(rows.filter { $0.hostPort == 16379 }.count == 2)
    }

    @Test func aZeroDateShowsAsNever() throws {
        let d = try make()
        #expect(d.finished == nil)
        #expect(d.created != nil && d.started != nil)
    }

    @Test func theNameHasNoLeadingSlash() throws {
        #expect(try make().name == "web-1")
        #expect(try make().imageRef == "nginx:alpine")
    }

    @Test func theRestartPolicyShowsTheRetryLimit() throws {
        let d = try make()
        #expect(d.restartPolicy == "on-failure:5")
        #expect(d.restartCount == 3)
    }

    @Test func noRestartPolicyIsNone() throws {
        let api = try JSONDecoder().decode(
            APIContainerDetail.self, from: Data(#"{"Id":"ab","HostConfig":{"RestartPolicy":{"Name":""}}}"#.utf8))
        #expect(ContainerDetail.make(from: api, digests: []).restartPolicy == "none")
    }

    @Test func anOutOfMemoryKillShows() throws {
        let d = try make()
        #expect(d.oomKilled)
        #expect(d.exitCode == 137)
    }

    @Test func theHealthLogHasTheLastThreeResultsNewestFirst() throws {
        let h = try #require(try make().health)
        #expect(h.status == "unhealthy")
        #expect(h.failingStreak == 4)
        #expect(h.log.map(\.exitCode) == [2, 1, 1])
        #expect(h.log[1].output == "third")
    }

    @Test func aHealthOutputIsOneLineOf200CharactersAtMost() throws {
        let line = try #require(try make().health?.log.first)
        #expect(!line.output.contains("\n") && !line.output.contains("\t") && !line.output.contains("  "))
        #expect(line.output.hasPrefix("line one line two xxx"))
        #expect(line.output.count == 201)
        #expect(line.output.hasSuffix("…"))
    }

    @Test func noHealthcheckGivesNoHealth() throws {
        let api = try JSONDecoder().decode(APIContainerDetail.self, from: Data(#"{"Id":"ab","State":{}}"#.utf8))
        #expect(ContainerDetail.make(from: api, digests: []).health == nil)
    }

    @Test func aLimitOfZeroMeansNoLimit() throws {
        let d = try make()
        #expect(d.memoryLimit == 0)
        #expect(d.memoryReservation == 268_435_456)
        #expect(d.cpus == 1.5)
        #expect(d.cpuShares == 0)
        #expect(d.pidsLimit == 0)
        #expect(d.privileged)
    }

    @Test func networksAreSortedByName() throws {
        #expect(try make().networks.map(\.name) == ["alpha", "zeta"])
        #expect(try make().networks[0].ipv6 == "fd00::2")
    }

    @Test func aliasesHaveNoDuplicatesAndNoShortID() throws {
        let zeta = try #require(try make().networks.last)
        #expect(zeta.aliases == ["web", "web-1"])
        #expect(try make().networks[0].aliases == [])
    }

    @Test func aVolumeMountShowsItsName() throws {
        let mounts = try make().mounts
        #expect(mounts[0] == .init(type: "bind", source: "/Users/ab/docs", destination: "/docs", readWrite: false))
        #expect(mounts[1] == .init(type: "volume", source: "data", destination: "/data", readWrite: true))
    }

    @Test func portsHaveOneRowForEachBindingAndNoRowForAnUnpublishedPort() throws {
        let ports = try make().ports
        // 18080 on 0.0.0.0 and on :: is one row.
        #expect(ports.map(\.hostPort) == [5353, 18080])
        #expect(ports[0] == .init(hostPort: 5353, containerPort: 53, proto: "udp", hostIP: "127.0.0.1"))
        #expect(!ports.contains { $0.containerPort == 9000 })
    }

    @Test func composeLabelsComeFirst() throws {
        let labels = try make().labels
        #expect(
            labels.map(\.key) == [
                "com.docker.compose.project", "com.docker.compose.service", "a.label", "b.label", "db.password",
            ])
        #expect(labels.filter(\.isCompose).count == 2)
    }

    @Test func aLabelWithASecretKeyIsSecret() throws {
        let labels = try make().labels
        #expect(labels.first { $0.key == "db.password" }?.isSecret == true)
        #expect(labels.first { $0.key == "a.label" }?.isSecret == false)
    }

    @Test func environmentEntriesKeepTheRawValueAndMarkSecrets() throws {
        let env = try make().env
        #expect(env.map(\.key) == ["PATH", "API_TOKEN", "URL", "NOVALUE"])
        #expect(env.map(\.isSecret) == [false, true, true, false])
        #expect(env[1].value == "abc")
    }

    @Test func anEntrypointOfNullIsEmpty() throws {
        let d = try make()
        #expect(d.entrypoint == [])
        #expect(d.command == ["nginx", "-g", "daemon off;"])
        #expect(d.workingDir == "/app")
    }

    @Test func anEntrypointGivenAsOneStringIsOneWord() throws {
        let json = #"{"Id":"ab","Config":{"Entrypoint":"/start.sh"}}"#
        let api = try JSONDecoder().decode(APIContainerDetail.self, from: Data(json.utf8))
        #expect(ContainerDetail.make(from: api, digests: []).entrypoint == ["/start.sh"])
    }

    @Test func theDigestIsTheHashOfTheFirstRepoDigest() throws {
        #expect(try make().digest == nil)
        #expect(try make(digests: ["nginx@sha256:abc123"]).digest == "sha256:abc123")
    }
}
