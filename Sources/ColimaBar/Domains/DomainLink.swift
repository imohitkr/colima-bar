import Foundation

/// Builds the link of a container name. The link comes from validated names
/// and an integer port, never from free text of a container.
enum DomainLink {
    /// `http://<relative>.<suffix>[:port]/`. The port is left out for 80 (http)
    /// and 443 (https).
    static func url(relative: String, suffix: String, secure: Bool, port: UInt16) -> URL? {
        let standard: UInt16 = secure ? 443 : 80
        let authority =
            port == standard
            ? host(relative: relative, suffix: suffix) : "\(host(relative: relative, suffix: suffix)):\(port)"
        return URL(string: "\(secure ? "https" : "http")://\(authority)/")
    }

    /// The full host name. An empty `relative` is the bare suffix.
    static func host(relative: String, suffix: String) -> String {
        relative.isEmpty ? suffix : "\(relative).\(suffix)"
    }
}
