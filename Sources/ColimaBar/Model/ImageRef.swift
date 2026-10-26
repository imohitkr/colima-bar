import Foundation

/// An image reference in its full form: registry, repository path and tag.
/// For example `nginx` is `docker.io/library/nginx:latest`. Pure.
struct ImageRef: Equatable, Hashable, Sendable {
    /// The registry host, with the port if there is one. Docker Hub is `docker.io`.
    let domain: String
    /// The repository path, for example `library/nginx`.
    let path: String
    let tag: String

    static let hub = "docker.io"

    /// The reference without the tag, for example `ghcr.io/x/y`.
    var repository: String { "\(domain)/\(path)" }
    /// The full reference. It is the key of the results.
    var normalized: String { "\(repository):\(tag)" }
    var isDockerHub: Bool { domain == Self.hub }

    /// The reference that a user typed or the daemon stored, or nil when the
    /// image has no tag to follow: a digest pin, an image ID, an empty or a
    /// bad name.
    static func parse(_ text: String) -> ImageRef? {
        guard !text.isEmpty, text.count <= 255, !text.contains("@"), !isImageID(text),
            text.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline })
        else { return nil }
        var rest = Substring(text)
        var domain = hub
        if let slash = rest.firstIndex(of: "/") {
            let head = rest[..<slash]
            if head.contains(".") || head.contains(":") || head == "localhost" {
                domain = String(head)
                rest = rest[rest.index(after: slash)...]
            }
        }
        if ["index.docker.io", "registry-1.docker.io"].contains(domain) { domain = hub }
        guard isValidDomain(domain) else { return nil }
        var tag = "latest"
        let lastSlash = rest.lastIndex(of: "/").map { rest.index(after: $0) } ?? rest.startIndex
        if let colon = rest[lastSlash...].firstIndex(of: ":") {
            tag = String(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }
        var path = String(rest)
        if domain == hub, !path.contains("/") { path = "library/" + path }
        guard isValidPath(path), isValidTag(tag) else { return nil }
        return ImageRef(domain: domain, path: path, tag: tag)
    }

    /// The normalized repository of an entry of `RepoDigests` and its digest,
    /// for example `nginx@sha256:…` gives `docker.io/library/nginx`.
    static func repoDigest(_ entry: String) -> (repository: String, digest: String)? {
        let parts = entry.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1].hasPrefix("sha256:"), let ref = parse(parts[0]) else { return nil }
        return (ref.repository, parts[1])
    }

    /// A `sha256:` prefix, or 12 to 64 lowercase hex digits, names an image ID.
    private static func isImageID(_ s: String) -> Bool {
        if s.hasPrefix("sha256:") { return true }
        return (12...64).contains(s.count) && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isValidDomain(_ d: String) -> Bool {
        let parts = d.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return false }
        if parts.count == 2, Int(parts[1]) == nil { return false }
        return parts[0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// Each part of the path is lowercase letters and digits, joined by `.`, `_`, `__` or `-`.
    private static func isValidPath(_ p: String) -> Bool {
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty
            && parts.allSatisfy {
                guard let first = $0.first, let last = $0.last else { return false }
                return $0.allSatisfy { c in c.isASCII && (c.isLowercase || c.isNumber || "._-".contains(c)) }
                    && (first.isLetter || first.isNumber) && (last.isLetter || last.isNumber)
            }
    }

    private static func isValidTag(_ t: String) -> Bool {
        guard (1...128).contains(t.count), let first = t.first else { return false }
        return (first.isASCII && (first.isLetter || first.isNumber || first == "_"))
            && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
