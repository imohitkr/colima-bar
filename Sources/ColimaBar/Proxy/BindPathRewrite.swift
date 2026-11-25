import Foundation

/// Rewrites the `/tmp` bind sources of a container create request to
/// `/private/tmp`.
///
/// On macOS, `/tmp` is a symlink to `/private/tmp`. The Docker daemon runs in
/// the VM and looks up a bind source in the VM, so `-v /tmp/x:/x` binds the
/// `/tmp` of the VM. That path does not exist, and Docker makes an empty
/// folder there. Docker Desktop changes `/tmp` to `/private/tmp` for the same
/// reason. If colima.yaml shares `/private/tmp` at the same path in the VM,
/// the rewritten source is the folder on the Mac.
///
/// The functions are pure, so tests need no socket and no VM.
enum BindPathRewrite {
    /// The Mac folder that `/tmp` links to.
    static let target = "/private/tmp"

    /// The largest create body that the proxy holds to rewrite. A larger body
    /// passes through unchanged. A normal create body is a few KB.
    static let maxBody = 1024 * 1024

    /// True for `POST /containers/create` and `POST /vX.Y/containers/create`,
    /// with or without a query string.
    static func isContainerCreate(_ requestLine: String) -> Bool {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return false }
        var path = Substring(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if path.hasPrefix("/v"), let slash = path.dropFirst().firstIndex(of: "/") {
            guard path[path.index(path.startIndex, offsetBy: 2)..<slash].allSatisfy({ $0.isNumber || $0 == "." })
            else { return false }
            path = path[slash...]
        }
        return path == "/containers/create"
    }

    /// The path under `/private/tmp` for a path that is `/tmp` or starts with
    /// `/tmp/`. Nil for any other path, for example `/tmpfoo`,
    /// `/private/tmp/x` or a named volume. Nil also for a path with a `..`
    /// part, because `..` resolves against another folder after the change.
    static func rewrittenSource(_ source: String) -> String? {
        guard source == "/tmp" || source.hasPrefix("/tmp/") else { return nil }
        guard !source.split(separator: "/").contains("..") else { return nil }
        return target + source.dropFirst("/tmp".count)
    }

    /// A `HostConfig.Binds` entry (`SRC:DST[:OPTIONS]`) with a new source, or
    /// nil if the source does not change.
    static func rewrittenBind(_ bind: String) -> String? {
        let source = bind.prefix { $0 != ":" }
        guard let new = rewrittenSource(String(source)) else { return nil }
        return new + bind.dropFirst(source.count)
    }

    /// The create body with new bind sources, or nil if no source changes or
    /// the body is not a JSON object. Only `HostConfig.Binds` and the
    /// `HostConfig.Mounts` entries of type `bind` change. Unknown fields stay.
    /// The keys come out sorted, so the same body always gives the same bytes;
    /// the Docker API does not depend on the key order.
    static func rewrittenBody(_ body: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            var host = root["HostConfig"] as? [String: Any]
        else { return nil }
        var changed = false
        if let binds = host["Binds"] as? [Any] {
            host["Binds"] = binds.map { item -> Any in
                guard let bind = item as? String, let new = rewrittenBind(bind) else { return item }
                changed = true
                return new
            }
        }
        if let mounts = host["Mounts"] as? [Any] {
            host["Mounts"] = mounts.map { item -> Any in
                guard var mount = item as? [String: Any], mount["Type"] as? String == "bind",
                    let source = mount["Source"] as? String, let new = rewrittenSource(source)
                else { return item }
                mount["Source"] = new
                changed = true
                return mount
            }
        }
        guard changed else { return nil }
        root["HostConfig"] = host
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The head and body of a create request with new bind sources and a new
    /// `Content-Length`, or nil if nothing changes. Nil also if the head has
    /// no `Content-Length` or more than one, because then the new length has
    /// no safe place.
    static func rewrittenRequest(head: Data, body: Data) -> Data? {
        guard let newBody = rewrittenBody(body), let newHead = withContentLength(head, newBody.count) else {
            return nil
        }
        return newHead + newBody
    }

    /// The head with its one `Content-Length` header set to `length`. Each
    /// other byte stays.
    static func withContentLength(_ head: Data, _ length: Int) -> Data? {
        let bytes = [UInt8](head)
        let name = Array("content-length:".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 8)
        var found = 0
        var i = 0
        while i < bytes.count {
            let end = bytes[i...].firstIndex(of: 0x0A).map { $0 + 1 } ?? bytes.count
            let line = bytes[i..<end]
            if line.count > name.count, zip(line, name).allSatisfy({ $0 | 0x20 == $1 }) {
                found += 1
                let ending = line.reversed().prefix { $0 == 0x0A || $0 == 0x0D }.count
                out += Array("Content-Length: \(length)".utf8) + line.suffix(ending)
            } else {
                out += line
            }
            i = end
        }
        return found == 1 ? Data(out) : nil
    }

    /// True if the mounts share the Mac's `/private/tmp` at `/private/tmp` in
    /// the VM. A share of `/private` also counts.
    static func sharesTarget(mounts: [VMMount], defaultHome: Bool, home: String) -> Bool {
        let mac = MountPathMap.macPath(vmPath: target, mounts: mounts, defaultHome: defaultHome, home: home)
        return mac == target || mac == "/tmp"
    }

    /// Reads the colima.yaml next to a Colima socket
    /// (`PROFILE_DIR/docker.sock`, see `Paths.socket`) and checks
    /// `sharesTarget`. False if the file is missing or cannot be read.
    static func sharesTarget(upstream: String) -> Bool {
        let config = (upstream as NSString).deletingLastPathComponent + "/colima.yaml"
        guard let yaml = try? String(contentsOfFile: config, encoding: .utf8) else { return false }
        let read = VMSettings.read(yaml)
        return sharesTarget(mounts: read.mounts, defaultHome: read.mountsDefaultHome, home: NSHomeDirectory())
    }
}
