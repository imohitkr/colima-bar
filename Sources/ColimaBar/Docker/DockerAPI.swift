import Darwin
import Foundation

/// Minimal Docker Engine API client over the Colima unix socket, the same
/// transport Portainer and the docker CLI use. Requests are HTTP/1.0 so the
/// daemon replies unchunked and closes the connection at the end of the body,
/// which keeps both one-shot and streaming reads trivial.
final class DockerAPI: Sendable {
    let socketPath: String

    /// The size of each read buffer. Each stats stream and log window holds
    /// one for as long as it is open, so this stays small.
    static let bufferSize = 16 * 1024

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    struct Response {
        let status: Int
        let headers: [String: String]  // lower-cased names
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
        var buf = [UInt8](repeating: 0, count: Self.bufferSize)
        while true {
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                return nil  // read timeout (SO_RCVTIMEO) or error: not a complete reply
            }
            data.append(buf, count: n)
        }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let (status, headers) = Self.parseHead(data[..<split.lowerBound])
        var body = Data(data[split.upperBound...])
        if headers["transfer-encoding"]?.lowercased() == "chunked" { body = Self.dechunk(body) }
        return Response(status: status, headers: headers, body: body)
    }

    static func parseHead(_ raw: Data) -> (Int, [String: String]) {
        let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
        }
        return (status, headers)
    }

    /// Like `stream`, but hands over raw body bytes as they arrive (for log
    /// streams, whose frames are binary rather than newline-delimited).
    func streamRaw(
        _ path: String, onData: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (StreamHandle) -> Void
    ) -> StreamHandle {
        openStream(path, onBody: onData, onEnd: onEnd)
    }

    /// Opens a long-lived request and calls `onLine` with each newline-delimited
    /// JSON object on a background thread. `onEnd` fires when the daemon closes
    /// it (VM stopped, container gone, or a non-2xx reply, see
    /// `StreamHandle.status`) but never after `cancel()`. It receives the
    /// handle, so owners can check it is still the one they track.
    func stream(
        _ path: String, onLine: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (StreamHandle) -> Void
    ) -> StreamHandle {
        let splitter = LineSplitter(onLine: onLine)
        return openStream(path, onBody: { splitter.feed($0) }, onEnd: onEnd)
    }

    private func openStream(
        _ path: String, onBody: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (StreamHandle) -> Void
    ) -> StreamHandle {
        let handle = StreamHandle()
        Thread.detachNewThread { [self] in
            let end = { if !handle.cancelled { onEnd(handle) } }
            guard let fd = connect(timeout: 0) else {
                end()
                return
            }
            guard handle.attach(fd) else {
                close(fd)
                return
            }
            defer { handle.finish() }
            guard send(fd, method: "GET", path: path) else {
                end()
                return
            }
            var pending = Data()
            var headerDone = false
            var buf = [UInt8](repeating: 0, count: Self.bufferSize)
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                if headerDone {
                    onBody(Data(buf[0..<n]))
                    continue
                }
                pending.append(buf, count: n)
                guard let split = pending.range(of: Data("\r\n\r\n".utf8)) else { continue }
                headerDone = true
                let (status, _) = Self.parseHead(pending[..<split.lowerBound])
                handle.setStatus(status)
                // An error reply is a JSON message, not stream data: feeding it
                // to a frame or line parser would misread it.
                guard (200..<300).contains(status) else { break }
                let rest = Data(pending[split.upperBound...])
                pending.removeAll()
                if !rest.isEmpty { onBody(rest) }
            }
            end()
        }
        return handle
    }

    // MARK: - Socket plumbing

    private func connect(timeout: Int) -> Int32? {
        UnixSocket.connect(socketPath, timeout: timeout)
    }

    private func send(_ fd: Int32, method: String, path: String) -> Bool {
        let req =
            "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nUser-Agent: ColimaBar\r\n"
            + (method == "GET" ? "" : "Content-Length: 0\r\n") + "\r\n"
        let bytes = Array(req.utf8)
        return bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) } == bytes.count
    }

    static func dechunk(_ d: Data) -> Data {
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
    static func percentEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

/// Cancels a stream by shutting its socket down, which unblocks the reader.
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var _cancelled = false
    private var _status: Int?

    var cancelled: Bool { lock.withLock { _cancelled } }
    /// HTTP status of the reply, once its head has arrived.
    var status: Int? { lock.withLock { _status } }

    fileprivate func setStatus(_ s: Int) { lock.withLock { _status = s } }

    fileprivate func attach(_ fd: Int32) -> Bool {
        lock.withLock {
            if _cancelled { return false }
            self.fd = fd
            return true
        }
    }

    fileprivate func finish() {
        lock.withLock {
            if fd >= 0 {
                close(fd)
                fd = -1
            }
        }
    }

    func cancel() {
        lock.withLock {
            _cancelled = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }
}

/// Splits a byte stream into newline-delimited lines. Used from one reader
/// thread only.
/// `@unchecked Sendable`: only the one reader thread touches `pending`.
final class LineSplitter: @unchecked Sendable {
    private var pending = Data()
    private let onLine: @Sendable (Data) -> Void

    init(onLine: @escaping @Sendable (Data) -> Void) { self.onLine = onLine }

    func feed(_ chunk: Data) {
        pending.append(chunk)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<nl])
            pending.removeSubrange(...nl)
            if !line.isEmpty { onLine(line) }
        }
    }
}
