import Foundation

/// The VM settings to write to colima.yaml. ColimaBar writes only the fields
/// that are set. A field that is nil stays as it is in the file.
struct VMSettingsChange: Equatable, Sendable {
    var dnsServers: [String]?
    /// `network.address`: a reachable IP address for the VM.
    var address: Bool?
    /// "ssh" or "grpc".
    var portForwarder: String?
    var mountInotify: Bool?
    var mounts: [VMMount]?
    var registryMirrors: [String]?
    var insecureRegistries: [String]?

    init(
        dnsServers: [String]? = nil, address: Bool? = nil, portForwarder: String? = nil,
        mountInotify: Bool? = nil, mounts: [VMMount]? = nil, registryMirrors: [String]? = nil,
        insecureRegistries: [String]? = nil
    ) {
        self.dnsServers = dnsServers
        self.address = address
        self.portForwarder = portForwarder
        self.mountInotify = mountInotify
        self.mounts = mounts
        self.registryMirrors = registryMirrors
        self.insecureRegistries = insecureRegistries
    }

    /// True if no field is set.
    var isEmpty: Bool { self == VMSettingsChange() }
}
