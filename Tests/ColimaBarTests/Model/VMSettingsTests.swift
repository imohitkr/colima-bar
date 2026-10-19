import Testing

@testable import ColimaBar

@Suite struct VMSettingsTests {
    @Test func anEmptyFileGivesTheColimaDefaults() {
        let r = VMSettings.read("")
        #expect(r == VMSettings.Read())
        #expect(r.portForwarder == "ssh" && r.usesVZ && r.usesDocker)
        #expect(VMSettings.Field.allCases.allSatisfy { r.isEditable($0) })
    }

    @Test func theVMTypeAndTheRuntimeDecideWhatTheFileSupports() {
        let qemu = VMSettings.read("vmType: qemu\nruntime: containerd\n")
        #expect(!qemu.usesVZ && !qemu.usesDocker)
        let vz = VMSettings.read("vmType: vz\nruntime: docker\n")
        #expect(vz.usesVZ && vz.usesDocker)
    }

    @Test func theValuesFixedAtCreationAreRead() {
        let r = VMSettings.read("arch: aarch64\nvmType: vz\nmountType: virtiofs\nruntime: docker\n")
        #expect(r.arch == "aarch64" && r.vmType == "vz" && r.mountType == "virtiofs" && r.runtime == "docker")
    }

    @Test func theFlagsAreReadFromTheirSections() {
        let r = VMSettings.read("network:\n  address: true\nmountInotify: true\nportForwarder: grpc\n")
        #expect(r.address && r.mountInotify && r.portForwarder == "grpc")
    }

    @Test func aFlagThatIsNotTrueOrFalseIsReadOnly() {
        let r = VMSettings.read("network:\n  address: maybe\nmountInotify: [true]\n")
        #expect(!r.isEditable(.address) && !r.isEditable(.mountInotify))
        #expect(r.isEditable(.mounts) && r.isEditable(.dnsServers))
    }

    @Test func aPortForwarderOtherThanSSHOrGRPCIsKept() {
        #expect(VMSettings.read("portForwarder: none\n").portForwarder == "none")
    }

    @Test func aMissingNullOrEmptyListIsEmpty() {
        for text in ["", "docker: {}\n", "docker:\n", "docker: null\n"] {
            let r = VMSettings.read(text)
            #expect(r.registryMirrors.isEmpty && r.isEditable(.registryMirrors), "\(text)")
        }
    }

    @Test func aPortForwarderThatIsNotAPlainValueIsReadOnly() {
        let r = VMSettings.read("portForwarder: [grpc]\n")
        #expect(!r.isEditable(.portForwarder) && r.portForwarder == "ssh")
        #expect(r.isEditable(.mounts))
    }

    @Test func aNullPortForwarderIsTheDefault() {
        let r = VMSettings.read("portForwarder:\n")
        #expect(r.isEditable(.portForwarder) && r.portForwarder == "ssh")
    }

    @Test func mountsInAFormThatTheEditorRefusesAreReadOnly() {
        let r = VMSettings.read("mounts: &home\n  - location: ~\n")
        #expect(!r.isEditable(.mounts) && r.mounts.isEmpty && !r.mountsDefaultHome)
        #expect(r.isEditable(.portForwarder))
    }

    @Test func onlyAnExplicitEmptyListMountsTheHomeFolder() {
        #expect(VMSettings.read("mounts: []\n").mountsDefaultHome)
        for text in ["", "cpu: 2\n", "mounts:\n", "mounts: null\n", "mounts: ~\n", "mounts:\n  - location: ~/code\n"] {
            let r = VMSettings.read(text)
            #expect(!r.mountsDefaultHome, "\(text)")
            #expect(r.isEditable(.mounts), "\(text)")
        }
    }
}
