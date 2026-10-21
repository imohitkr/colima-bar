import Testing

@testable import ColimaBar

@Suite struct VMTypeRulesTests {
    @Test func eachVMTypeTakesItsOwnMountTypesAndDefault() {
        #expect(VMTypeRules.vmTypes == ["vz", "qemu"])
        #expect(VMTypeRules.mountTypes(for: "vz") == ["virtiofs", "sshfs"])
        #expect(VMTypeRules.mountTypes(for: "qemu") == ["sshfs", "9p"])
        #expect(VMTypeRules.mountTypes(for: "krunkit").isEmpty)
        #expect(VMTypeRules.defaultMountType(for: "vz") == "virtiofs")
        #expect(VMTypeRules.defaultMountType(for: "qemu") == "sshfs")
        #expect(VMTypeRules.defaultMountType(for: "krunkit") == "")
    }

    @Test func onlyThePairsOfTheTableAreValid() {
        let valid: Set<String> = ["vz/virtiofs", "vz/sshfs", "qemu/sshfs", "qemu/9p"]
        for vm in ["vz", "qemu", "krunkit", ""] {
            for mount in ["virtiofs", "sshfs", "9p", "nfs", ""] {
                #expect(VMTypeRules.isValid(vmType: vm, mountType: mount) == valid.contains("\(vm)/\(mount)"))
            }
        }
    }

    @Test func missingKeysMeanVZAndTheDefaultMountType() {
        #expect(VMTypeRules.effective(vmType: "", mountType: "") == ("vz", "virtiofs"))
        #expect(VMTypeRules.effective(vmType: "qemu", mountType: "") == ("qemu", "sshfs"))
        #expect(VMTypeRules.effective(vmType: "", mountType: "sshfs") == ("vz", "sshfs"))
        #expect(VMTypeRules.effective(vmType: "krunkit", mountType: "") == ("krunkit", ""))
    }

    @Test func theHostArchitectureIsArmOrUnset() {
        for arch in ["", "aarch64", "arm64"] { #expect(VMTypeRules.isHostArch(arch)) }
        for arch in ["x86_64", "amd64"] { #expect(!VMTypeRules.isHostArch(arch)) }
    }

    @Test func qemuIsInstalledOnlyWithBothProgramsInAHomebrewFolder() {
        func found(_ paths: Set<String>, arch: String = "") -> Bool {
            VMTypeRules.qemuInstalled(arch: arch, isExecutable: { paths.contains($0) })
        }
        let arm: Set = ["/opt/homebrew/bin/qemu-img", "/opt/homebrew/bin/qemu-system-aarch64"]
        #expect(found(arm))
        #expect(found(["/usr/local/bin/qemu-img", "/usr/local/bin/qemu-system-aarch64"]))
        #expect(!found(["/opt/homebrew/bin/qemu-img"]))
        #expect(!found(["/opt/homebrew/bin/qemu-system-aarch64"]))
        #expect(!found(arm, arch: "x86_64"))
        #expect(found(["/opt/homebrew/bin/qemu-img", "/opt/homebrew/bin/qemu-system-x86_64"], arch: "x86_64"))
        #expect(!found([]))
    }
}
