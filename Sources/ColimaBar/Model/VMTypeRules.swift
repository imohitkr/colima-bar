import Foundation

/// The VM types and mount types that ColimaBar sets, and which pairs work.
/// Colima changes a wrong pair without a word (vz with 9p becomes virtiofs),
/// so ColimaBar refuses it. The lists must be the same as `recreate_pair_ok`
/// in colima-ctl.sh: a test checks this.
enum VMTypeRules {
    /// The VM types that ColimaBar offers. krunkit needs an extra program.
    static let vmTypes = ["vz", "qemu"]

    /// The mount types that the VM type takes. The first one is the default.
    static func mountTypes(for vmType: String) -> [String] {
        switch vmType {
        case "vz": ["virtiofs", "sshfs"]
        case "qemu": ["sshfs", "9p"]
        default: []
        }
    }

    /// The mount type that Colima uses for a VM type, or "" for an unknown type.
    static func defaultMountType(for vmType: String) -> String {
        mountTypes(for: vmType).first ?? ""
    }

    static func isValid(vmType: String, mountType: String) -> Bool {
        mountTypes(for: vmType).contains(mountType)
    }

    /// What Colima uses for the values of colima.yaml: no VM type is vz, and no
    /// mount type is the default of the VM type.
    static func effective(vmType: String, mountType: String) -> (vmType: String, mountType: String) {
        let type = vmType.isEmpty ? "vz" : vmType
        return (type, mountType.isEmpty ? defaultMountType(for: type) : mountType)
    }

    /// True for the architecture of this Mac (Apple silicon), or no value.
    static func isHostArch(_ arch: String) -> Bool {
        ["", "aarch64", "arm64"].contains(arch)
    }

    /// True if QEMU for `arch` is in a folder of the PATH of colima-ctl.sh
    /// (`brew install qemu`).
    static func qemuInstalled(
        arch: String, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> Bool {
        let system = isHostArch(arch) ? "qemu-system-aarch64" : "qemu-system-x86_64"
        return ["/opt/homebrew/bin", "/usr/local/bin"].contains { dir in
            isExecutable("\(dir)/qemu-img") && isExecutable("\(dir)/\(system)")
        }
    }
}
