import Darwin
import Foundation

/// Minimal Docker Engine API client over the Colima unix socket, the same
/// transport Portainer and the docker CLI use. Requests are HTTP/1.0 so the
/// daemon replies unchunked and closes the connection at the end of the body,
/// which keeps both one-shot and streaming reads trivial.
final class DockerAPI: @unchecked Sendable {
    let socketPath: String

    init(socketPath: String = "\(Shell.home)/.config/colima/default/docker.sock") {
        self.socketPath = socketPath
    }

    struct Response {
        let status: Int
        let body: Data
        var ok: Bool { (200..<300).contains(status) }
    }

    func get(_ path: String, timeout: Int = 15) async -> Response? {
        await request("GET", path, timeout: timeout)
    }

    func post(_ path: String, timeout: Int = 60) async -> Response? {
        await request("POST", path, timeout: timeout)
    }

    func request(_ method: String, _ path: String, timeout: Int = 15) async -> Response? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.requestSync(method, path, timeout: timeout))
            }
        }
    }

    private func requestSync(_ method: String, _ path: String, timeout: Int) -> Response? {
        guard let fd = connect(timeout: timeout) else { return nil }
        defer { close(fd) }
        guard send(fd, method: method, path: path) else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let status = head.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? 0
        var body = Data(data[split.upperBound...])
        if head.lowercased().contains("transfer-encoding: chunked") { body = Self.dechunk(body) }
        return Response(status: status, body: body)
    }

    /// Opens a long-lived request and calls `onLine` with each newline-delimited
    /// JSON object on a background thread. `onEnd` fires when the daemon closes
    /// it (VM stopped, container gone) but not after `cancel()`.
    func stream(_ path: String, onLine: @escaping @Sendable (Data) -> Void,
                onEnd: @escaping @Sendable () -> Void) -> StreamHandle {
        let handle = StreamHandle()
        Thread.detachNewThread { [self] in
            guard let fd = connect(timeout: 0) else { onEnd(); return }
            guard handle.attach(fd) else { close(fd); return }
            defer { handle.finish() }
            guard send(fd, method: "GET", path: path) else { if !handle.cancelled { onEnd() }; return }
            var pending = Data()
            var headerDone = false
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                pending.append(buf, count: n)
                if !headerDone {
                    guard let split = pending.range(of: Data("\r\n\r\n".utf8)) else { continue }
                    pending.removeSubrange(..<split.upperBound)
                    headerDone = true
                }
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<nl])
                    pending.removeSubrange(...nl)
                    if !line.isEmpty { onLine(line) }
                }
            }
            if !handle.cancelled { onEnd() }
        }
        return handle
    }

    // MARK: - Socket plumbing

    private func connect(timeout: Int) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path)
            raw[path.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if timeout > 0 {
            var tv = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        return fd
    }

    private func send(_ fd: Int32, method: String, path: String) -> Bool {
        let req = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nUser-Agent: ColimaBar\r\n"
            + (method == "GET" ? "" : "Content-Length: 0\r\n") + "\r\n"
        let bytes = Array(req.utf8)
        return bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) } == bytes.count
    }

    private static func dechunk(_ d: Data) -> Data {
        var out = Data()
        var i = d.startIndex
        while i < d.endIndex, let crlf = d[i...].range(of: Data("\r\n".utf8)) {
            let sizeHex = String(decoding: d[i..<crlf.lowerBound], as: UTF8.self)
            guard let size = Int(sizeHex.split(separator: ";").first ?? "", radix: 16), size > 0 else { break }
            let start = crlf.upperBound
            let end = min(start + size, d.endIndex)
            out.append(d[start..<end])
            i = min(end + 2, d.endIndex)
        }
        return out
    }

    /// Percent-encodes a query value (filters JSON etc.).
    static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

/// Cancels a stream by shutting its socket down, which unblocks the reader.
final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var cancelled = false

    fileprivate func attach(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        self.fd = fd
        return true
    }

    fileprivate func finish() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
}
