import Foundation
import Testing

@testable import ColimaBar

@Suite struct ColimaConfigSummaryTests {
    private func lines(_ yaml: String) -> [String] { ColimaConfigSummary.lines(of: yaml) }

    @Test func showsTheValuesOfTheSimpleKeys() {
        let out = lines("cpu: 4\nmemory: 8\ndisk: 100\nvmType: vz\nrosetta: true\nruntime: docker\n")
        #expect(out == ["cpu: 4", "memory: 8", "disk: 100", "vmType: vz", "rosetta: true", "runtime: docker"])
    }

    @Test func neverShowsTheValuesOfEnvOrProvision() {
        let yaml = """
            cpu: 2
            env:
              API_TOKEN: hunter2
            provision:
              - mode: user
                script: echo hunter2
            docker:
              insecure-registries: ["secret.corp:5000"]
            hostname: jane-laptop
            diskImage: /Users/jane/img.qcow2
            mounts:
            - location: /Users/jane/work
            """
        let out = lines(yaml)
        #expect(out.joined().contains("hunter2") == false)
        #expect(out.joined().contains("jane") == false)
        #expect(out.contains("env: set (not included)"))
        #expect(out.contains("provision: set (not included)"))
        #expect(out.contains("docker: set (not included)"))
        #expect(out.contains("hostname: set (not included)"))
        #expect(out.contains("diskImage: set (not included)"))
        #expect(out.contains("mounts: set (not included)"))
    }

    @Test func anInlineEmptyValueIsEmpty() {
        let out = lines("env: {}\nprovision: []\nhostname: \"\"\nmounts:\n")
        #expect(out == ["env: empty", "provision: empty", "hostname: empty", "mounts: empty"])
    }

    @Test func listsTheKeysOfKubernetesAndNetworkOneByOne() {
        let yaml = """
            kubernetes:
              enabled: true
              version: v1.31.2+k3s1
              k3sArgs:
                - --disable=traefik
            network:
              address: false
              dns:
                - 10.1.1.1
              mode: shared
            """
        #expect(
            lines(yaml) == [
                "kubernetes.enabled: true", "kubernetes.version: v1.31.2+k3s1",
                "kubernetes.k3sArgs: set (not included)",
                "network.address: false", "network.dns: set (not included)", "network.mode: shared",
            ])
    }

    @Test func readsCRLFCommentsAndQuotes() {
        let out = lines("cpu: 4 # four cores\r\nvmType: \"vz\"\r\n# note\r\narch: 'aarch64'\r\n")
        #expect(out == ["cpu: 4", "vmType: vz", "arch: aarch64"])
    }

    @Test func cutsALongValue() {
        let out = lines("cpuType: " + String(repeating: "x", count: 200))
        #expect(out.first?.count == "cpuType: ".count + 60)
    }
}
