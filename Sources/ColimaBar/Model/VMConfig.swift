import Foundation

/// The VM settings in the colima.yaml of a profile. For a stopped VM,
/// `colima list` shows the values of the last start, not the file. Thus the
/// settings of a stopped VM come from here.
struct VMConfig: Equatable, Sendable {
    var cpus: Int?
    /// GiB, a decimal number as in Colima: `memory: 2.5` is 2.5 GiB.
    var memGB: Double?
    var diskGB: Int?
    var rosetta = false
    var kubernetes = false
    /// "vz", "qemu" or "" when the key is missing.
    var vmType = ""
    /// "docker", "containerd" or "" when the key is missing.
    var runtime = ""

    /// The values that the VM settings show.
    struct Shown: Equatable {
        var cpus = 0
        var memGB = 0.0
        var diskGB = 0
        var rosetta = false
        var kubernetes = false
        var rosettaSupported = true

        /// Rosetta needs the vz VM type. A switch that is on stays usable,
        /// so you can turn Rosetta off.
        var rosettaToggleDisabled: Bool { !rosettaSupported && !rosetta }
    }

    /// Reads the settings from the text of colima.yaml. A missing or bad
    /// key gives nil or the default. colima-ctl.sh reads the same forms
    /// (`yaml_value`): CRLF line ends, inline comments and quotes.
    static func parse(_ text: String) -> VMConfig {
        // Swift reads "\r\n" as one character, so a CRLF file has no "\n"
        // to split at.
        let yaml = text.replacingOccurrences(of: "\r", with: "")
        func value(_ key: String, section: String? = nil) -> String? {
            guard var v = Parse.yaml(yaml, key: key, section: section) else { return nil }
            // An inline comment: "cpu: 4 # four cores".
            if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
            v = v.trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }
        func number(_ key: String) -> Double? {
            guard let v = value(key), let d = Double(v), d.isFinite, d >= 0, d < Double(Int.max) else { return nil }
            return d
        }
        // Colima reads CPU and disk as whole numbers. A fraction is cut off,
        // as colima-ctl.sh does: `disk: 100.0` is 100.
        func whole(_ key: String) -> Int? { number(key).map { Int($0) } }
        return VMConfig(
            cpus: whole("cpu"),
            memGB: number("memory"),
            diskGB: whole("disk"),
            rosetta: value("rosetta") == "true",
            kubernetes: value("enabled", section: "kubernetes") == "true",
            vmType: value("vmType") ?? "",
            runtime: value("runtime") ?? "")
    }

    /// Rosetta works only with the vz VM type. Colima on Apple silicon
    /// uses vz when colima.yaml names no VM type.
    var rosettaSupported: Bool { vmType.isEmpty || vmType == "vz" }

    /// The values that the VM settings show. A running VM shows its live
    /// CPU, memory and disk. A stopped VM shows colima.yaml, and the last
    /// `colima list` values for a key that the file does not have. Rosetta
    /// and Kubernetes always come from colima.yaml.
    static func shown(running: Bool, vm: VMInfo, config: VMConfig?) -> Shown {
        let file = running ? nil : config
        return Shown(
            cpus: file?.cpus ?? vm.cpus,
            memGB: file?.memGB ?? vm.memGB,
            diskGB: file?.diskGB ?? vm.diskGB,
            rosetta: config?.rosetta ?? false,
            kubernetes: config?.kubernetes ?? false,
            rosettaSupported: config?.rosettaSupported ?? true)
    }
}
