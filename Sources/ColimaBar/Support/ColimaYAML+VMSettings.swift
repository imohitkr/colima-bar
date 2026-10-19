import Foundation

extension ColimaYAML {
    /// The text of colima.yaml with the fields of the change. A field that
    /// already has the new value stays as it is, with its comments. It throws
    /// `Failure.unsupported` for a field in a form that the editor refuses.
    static func apply(_ change: VMSettingsChange, to text: String) throws -> String {
        let current = VMSettings.read(text)
        var out = text
        func edit<T: Equatable>(
            _ new: T?, _ old: T, _ field: VMSettings.Field, _ key: String, _ write: (T, String) throws -> String
        ) throws {
            guard let new, new != old else { return }
            guard current.isEditable(field) else { throw Failure.unsupported(key) }
            out = try write(new, out)
        }
        try edit(change.dnsServers, current.dnsServers, .dnsServers, "network.dns") {
            try setList(["network", "dns"], to: $0, in: $1)
        }
        try edit(change.address, current.address, .address, "network.address") {
            try setScalar(["network", "address"], to: "\($0)", in: $1)
        }
        try edit(change.portForwarder, current.portForwarder, .portForwarder, "portForwarder") {
            try setScalar(["portForwarder"], to: $0, in: $1)
        }
        try edit(change.mountInotify, current.mountInotify, .mountInotify, "mountInotify") {
            try setScalar(["mountInotify"], to: "\($0)", in: $1)
        }
        try edit(change.mounts, current.mounts, .mounts, "mounts") { try setMounts($0, in: $1) }
        try edit(change.registryMirrors, current.registryMirrors, .registryMirrors, "docker.registry-mirrors") {
            try setList(["docker", "registry-mirrors"], to: $0, in: $1)
        }
        try edit(
            change.insecureRegistries, current.insecureRegistries, .insecureRegistries, "docker.insecure-registries"
        ) { try setList(["docker", "insecure-registries"], to: $0, in: $1) }
        return out
    }
}
