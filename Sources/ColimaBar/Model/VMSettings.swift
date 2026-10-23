import Foundation

/// The VM settings of colima.yaml that ColimaBar edits (see `ColimaYAML`).
enum VMSettings {
    /// A setting that ColimaBar edits.
    enum Field: CaseIterable, Sendable {
        case dnsServers, address, portForwarder, mountInotify, mounts, registryMirrors, insecureRegistries
    }

    /// What colima.yaml says. A missing key gives the default of Colima.
    struct Read: Equatable, Sendable {
        var dnsServers: [String] = []
        var address = false
        /// "ssh" if the file has no value.
        var portForwarder = "ssh"
        var mountInotify = false
        var mounts: [VMMount] = []
        /// True for an explicit `mounts: []`: Colima then mounts the home
        /// folder, writable. With no `mounts` key, or `null`, it mounts
        /// nothing.
        var mountsDefaultHome = false
        var registryMirrors: [String] = []
        var insecureRegistries: [String] = []
        /// The values that Colima fixes when it creates the VM. "" if the
        /// key is missing.
        var vmType = ""
        var mountType = ""
        var arch = ""
        var runtime = ""
        /// True if `vmType` or `mountType` has a form that ColimaBar cannot
        /// read (a list or a map). Their values above are empty then.
        var typesUnreadable = false
        /// `network.mode`, for example "shared" or "bridged". "" if missing.
        var networkMode = ""
        /// `rosetta: true`.
        var rosetta = false
        /// `kubernetes.enabled: true`.
        var kubernetes = false
        /// The fields in a form that ColimaBar cannot edit (an anchor, a
        /// list over several lines, a mount with more keys). Their values
        /// above are empty or default.
        var readOnly: Set<Field> = []

        func isEditable(_ field: Field) -> Bool { !readOnly.contains(field) }

        /// Colima uses vz on Apple silicon if colima.yaml names no VM type.
        var usesVZ: Bool { vmType.isEmpty || vmType == "vz" }
        /// Colima starts a Docker daemon if colima.yaml names no runtime.
        var usesDocker: Bool { runtime.isEmpty || runtime == "docker" }
    }

    /// Reads the settings from the text of colima.yaml.
    static func read(_ yaml: String) -> Read {
        var r = Read()
        func guarded<T>(_ field: Field?, _ body: () throws -> T?) -> T? {
            do {
                return try body()
            } catch {
                if let field { r.readOnly.insert(field) }
                return nil
            }
        }
        func scalar(_ path: [String], _ field: Field? = nil) -> String? {
            guarded(field) {
                switch try ColimaYAML.value(path, in: yaml) {
                case .scalar(let s)?: return s
                case nil, .null?: return nil
                default:
                    // A list or a map where a plain value belongs: do not edit it.
                    if field != nil { throw ColimaYAML.Failure.unsupported(path.joined(separator: ".")) }
                    return nil
                }
            }
        }
        func list(_ path: [String], _ field: Field) -> [String] {
            guarded(field) { () -> [String]? in
                switch try ColimaYAML.value(path, in: yaml) {
                case .list(let items)?: return items
                case nil, .null?: return []
                default: throw ColimaYAML.Failure.unsupported(path.joined(separator: "."))
                }
            } ?? []
        }
        func flag(_ path: [String], _ field: Field) -> Bool {
            guarded(field) { () -> Bool? in
                switch try ColimaYAML.value(path, in: yaml) {
                case .scalar("true")?: return true
                case .scalar("false")?, nil, .null?: return false
                default: throw ColimaYAML.Failure.unsupported(path.joined(separator: "."))
                }
            } ?? false
        }
        r.dnsServers = list(["network", "dns"], .dnsServers)
        r.address = flag(["network", "address"], .address)
        r.mountInotify = flag(["mountInotify"], .mountInotify)
        r.registryMirrors = list(["docker", "registry-mirrors"], .registryMirrors)
        r.insecureRegistries = list(["docker", "insecure-registries"], .insecureRegistries)
        r.mounts = guarded(.mounts) { try ColimaYAML.mounts(in: yaml) } ?? []
        r.mountsDefaultHome = guarded(.mounts) { try ColimaYAML.hasEmptyMounts(in: yaml) } ?? false
        r.portForwarder = scalar(["portForwarder"], .portForwarder) ?? "ssh"
        func fixed(_ key: String) -> String {
            do {
                switch try ColimaYAML.value([key], in: yaml) {
                case .scalar(let s)?: return s
                case nil, .null?: return ""
                default: break
                }
            } catch {}
            r.typesUnreadable = true
            return ""
        }
        r.vmType = fixed("vmType")
        r.mountType = fixed("mountType")
        r.arch = scalar(["arch"]) ?? ""
        r.runtime = scalar(["runtime"]) ?? ""
        r.networkMode = scalar(["network", "mode"]) ?? ""
        r.rosetta = scalar(["rosetta"]) == "true"
        r.kubernetes = scalar(["kubernetes", "enabled"]) == "true"
        return r
    }
}
