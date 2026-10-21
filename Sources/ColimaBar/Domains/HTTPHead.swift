import Foundation

/// The head of an HTTP/1.x request, as far as the proxy needs it: the Host.
/// The parser is strict, because the proxy forwards the bytes as they are
/// and a lenient parse could read another Host than the upstream does.
struct HTTPHead: Equatable, Sendable {
    let method: String
    let target: String
    let version: String
    /// The authority of an absolute-form target, else the single Host value.
    let host: String?
    /// The bytes up to and with the empty line.
    let length: Int

    enum Problem: Error, Equatable {
        case incomplete
        case tooLarge
        case malformed
        case noHost
        case duplicateHost
    }

    /// The same limit as `SocketProxy.maxHead`.
    static let maxBytes = 64 * 1024

    var isHead: Bool { method == "HEAD" }

    static func parse(_ bytes: [UInt8]) -> Result<HTTPHead, Problem> {
        guard let end = headEnd(bytes) else {
            return .failure(bytes.count >= maxBytes ? .tooLarge : .incomplete)
        }
        guard end <= maxBytes else { return .failure(.tooLarge) }
        // Latin-1 maps each byte to one character, so no byte makes the text fail.
        let text = String(bytes[0..<(end - 4)].map { Character(Unicode.Scalar($0)) })
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, isToken(request[0]), !request[1].isEmpty,
            request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0"
        else { return .failure(.malformed) }
        var hosts: [String] = []
        for line in lines.dropFirst() {
            guard let first = line.first, first != " ", first != "\t" else { return .failure(.malformed) }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .failure(.malformed) }
            let name = line[..<colon]
            guard isToken(name) else { return .failure(.malformed) }
            if name.lowercased() == "host" {
                hosts.append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        guard hosts.count <= 1 else { return .failure(.duplicateHost) }
        let target = String(request[1])
        let absolute = authority(ofAbsolute: target)
        // The proxy routes by one name, but the upstream may read the other. A mismatch is an attack shape.
        if let absolute, let header = hosts.first, !sameAuthority(absolute, header) { return .failure(.malformed) }
        let host = absolute ?? hosts.first
        guard let host, !host.isEmpty else { return .failure(.noHost) }
        return .success(
            HTTPHead(method: String(request[0]), target: target, version: String(request[2]), host: host, length: end))
    }

    /// True when two authorities name the same host. The port may differ.
    private static func sameAuthority(_ a: String, _ b: String) -> Bool {
        if let x = DomainName.normalizedHost(a), let y = DomainName.normalizedHost(b) { return x == y }
        return a.trimmingCharacters(in: .whitespaces).lowercased()
            == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The index after the first CRLFCRLF, or nil.
    private static func headEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    private static func isToken(_ s: Substring) -> Bool {
        !s.isEmpty
            && s.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                    || "!#$%&'*+-.^_`|~".utf8.contains($0)
            }
    }

    /// `host:port` of `http://host:port/path`. Text before an `@` is no part of it.
    private static func authority(ofAbsolute target: String) -> String? {
        let lower = target.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        let rest = target.dropFirst(lower.hasPrefix("http://") ? 7 : 8)
        var auth = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = auth.lastIndex(of: "@") { auth = auth[auth.index(after: at)...] }
        return String(auth)
    }
}
