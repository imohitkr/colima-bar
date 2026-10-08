import Foundation
import Testing

@testable import ColimaBar

@Suite struct VMConfigTests {
    /// A shortened colima.yaml as Colima writes it.
    private let yaml = """
        # Number of CPUs to be allocated to the virtual machine.
        # Default: 2
        cpu: 4

        # Size of the disk in GiB to be allocated to the virtual machine.
        disk: 100

        # Size of the memory in GiB to be allocated to the virtual machine.
        memory: 8

        arch: aarch64
        runtime: docker

        # Kubernetes configuration for the virtual machine.
        kubernetes:
          # Enable kubernetes.
          enabled: true
          version: v1.33.4+k3s1

        vmType: vz
        rosetta: true
        """

    @Test func readsTheKeys() {
        let c = VMConfig.parse(yaml)
        #expect(c.cpus == 4)
        #expect(c.memGB == 8)
        #expect(c.diskGB == 100)
        #expect(c.rosetta)
        #expect(c.kubernetes)
        #expect(c.vmType == "vz")
        #expect(c.runtime == "docker")
    }

    @Test func missingKeysGiveNilOrTheDefault() {
        let c = VMConfig.parse("cpu: 2\n")
        #expect(c == VMConfig(cpus: 2))
        #expect(VMConfig.parse("") == VMConfig())
        #expect(VMConfig.parse("cpu: many\n").cpus == nil)
    }

    @Test func ignoresCommentsAndQuotes() {
        let c = VMConfig.parse("# cpu: 9\ncpu: 6 # six cores\nvmType: \"qemu\"\nrosetta: false # off\n")
        #expect(c.cpus == 6)
        #expect(c.vmType == "qemu")
        #expect(!c.rosetta)
    }

    @Test func readsKubernetesOnlyInItsSection() {
        // Another section with an "enabled" key does not count.
        let other = "network:\n  enabled: true\nkubernetes:\n  enabled: false\n"
        #expect(!VMConfig.parse(other).kubernetes)
        let after = "kubernetes:\n  version: v1\ncpu: 2\n  enabled: true\n"
        #expect(!VMConfig.parse(after).kubernetes)
    }

    @Test func cutsOffAFractionOfMemory() {
        // Colima and colima-ctl.sh also cut it off.
        #expect(VMConfig.parse("memory: 2.5\n").memGB == 2)
        #expect(VMConfig.parse("memory: 3.9\n").memGB == 3)
        #expect(VMConfig.parse("memory: 0.5\n").memGB == 0)
        #expect(VMConfig.parse("memory: -1\n").memGB == nil)
        #expect(VMConfig.parse("memory: 1e300\n").memGB == nil)
    }

    @Test func readsACRLFFile() {
        let c = VMConfig.parse("cpu: 4\r\ndisk: \"100\" # GiB\r\nkubernetes:\r\n  enabled: true\r\nvmType: qemu\r\n")
        #expect(c.cpus == 4)
        #expect(c.diskGB == 100)
        #expect(c.kubernetes)
        #expect(c.vmType == "qemu")
    }

    @Test func rosettaNeedsTheVZVMType() {
        #expect(VMConfig(vmType: "vz").rosettaSupported)
        #expect(VMConfig(vmType: "").rosettaSupported)  // Colima's default on Apple silicon
        #expect(!VMConfig(vmType: "qemu").rosettaSupported)
    }

    @Test func aRunningVMShowsItsLiveValues() {
        let vm = VMInfo(cpus: 2, memGB: 4, diskGB: 60)
        let config = VMConfig(cpus: 8, memGB: 16, diskGB: 200, rosetta: true, kubernetes: true, vmType: "qemu")
        let s = VMConfig.shown(running: true, vm: vm, config: config)
        #expect(
            s == VMConfig.Shown(cpus: 2, memGB: 4, diskGB: 60, rosetta: true, kubernetes: true, rosettaSupported: false)
        )
    }

    @Test func aStoppedVMShowsColimaYAML() {
        let vm = VMInfo(cpus: 2, memGB: 4, diskGB: 60)
        let config = VMConfig(cpus: 8, memGB: 16, diskGB: 200, rosetta: true)
        let s = VMConfig.shown(running: false, vm: vm, config: config)
        #expect(s == VMConfig.Shown(cpus: 8, memGB: 16, diskGB: 200, rosetta: true))
    }

    @Test func aStoppedVMFallsBackToTheListForAMissingKey() {
        let vm = VMInfo(cpus: 2, memGB: 4, diskGB: 60)
        let s = VMConfig.shown(running: false, vm: vm, config: VMConfig(memGB: 12))
        #expect(s.cpus == 2 && s.memGB == 12 && s.diskGB == 60)
        let none = VMConfig.shown(running: false, vm: vm, config: nil)
        #expect(none == VMConfig.Shown(cpus: 2, memGB: 4, diskGB: 60))
    }
}
