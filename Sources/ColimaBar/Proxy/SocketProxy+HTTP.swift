import Foundation

extension SocketProxy {
    /// Only ENOENT (no socket file) and ECONNREFUSED (stale socket file)
    /// mean that the VM is down. Other errors, such as EMFILE when this
    /// process runs out of fds, must not start Colima.
    static func meansVMDown(_ err: Int32) -> Bool { err == ENOENT || err == ECONNREFUSED }

    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]

    /// The first line of a chunk, if the chunk starts an HTTP request: a
    /// known method, a space and a "/" path. Body bytes (a build context tar
    /// that starts with "Dockerfile", JSON, HTTP/2 frames) give "".
    static func requestLine(_ buf: [UInt8], _ n: Int) -> String {
        buf.withUnsafeBytes { requestLine(UnsafeRawBufferPointer(rebasing: $0[0..<min(max(n, 0), $0.count)])) }
    }

    /// requestLine for raw bytes. It reads at most the first 512 bytes and
    /// copies nothing except the line it returns.
    static func requestLine(_ chunk: UnsafeRawBufferPointer) -> String {
        let head = UnsafeRawBufferPointer(rebasing: chunk.prefix(512))
        guard let space = head.prefix(8).firstIndex(of: 0x20), space + 1 < head.count, head[space + 1] == 0x2F,
            methods.contains(String(decoding: head[..<space], as: UTF8.self))
        else { return "" }
        return String(decoding: head.prefix { $0 != 0x0D && $0 != 0x0A }, as: UTF8.self)
    }

    /// The request line of the last request that starts in a chunk, or "" if
    /// the chunk does not start a request. A client can send several requests
    /// in one write, for example a pull and then a poll; the last one decides.
    /// It goes from head to head and skips each body by its Content-Length.
    /// It stops at a chunked body, at a head that the chunk cuts off, or at
    /// bytes that do not start a request. So body bytes never count as a request.
    static func lastRequestLine(_ chunk: UnsafeRawBufferPointer) -> String {
        var line = requestLine(chunk)
        guard !line.isEmpty, let base = chunk.baseAddress else { return line }
        var start = 0
        while true {
            // The end of this request's head.
            guard let found = memmem(base + start, chunk.count - start, "\r\n\r\n", 4) else { break }
            let headEnd = base.distance(to: UnsafeRawPointer(found)) + 4
            guard let body = bodyLength(UnsafeRawBufferPointer(rebasing: chunk[start..<headEnd])),
                body < chunk.count - headEnd
            else { break }
            let next = requestLine(UnsafeRawBufferPointer(rebasing: chunk[(headEnd + body)...]))
            guard !next.isEmpty else { break }
            line = next
            start = headEnd + body
        }
        return line
    }

    /// The body size that a request head announces: its Content-Length, or 0
    /// without one. nil for a chunked body or a bad Content-Length.
    static func bodyLength(_ head: UnsafeRawBufferPointer) -> Int? {
        func hasName(_ line: Slice<UnsafeRawBufferPointer>, _ name: StaticString) -> Bool {
            let n = UnsafeRawBufferPointer(start: name.utf8Start, count: name.utf8CodeUnitCount)
            guard line.count > n.count, line[line.startIndex + n.count] == 0x3A else { return false }
            return zip(line, n).allSatisfy { $0 | 0x20 == $1 }  // the names are lower case
        }
        var length = 0
        var i = 0
        while i < head.count {
            let end = head[i...].firstIndex(of: 0x0A) ?? head.count
            let line = head[i..<end]
            i = end + 1
            if hasName(line, "transfer-encoding") { return nil }
            guard hasName(line, "content-length") else { continue }
            let value = line.dropFirst("content-length:".utf8.count).filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }
            guard !value.isEmpty, value.count <= 15, value.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            length = value.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        return length
    }

    /// The method and path of a request line, without the query string.
    /// A query can carry secrets (`POST /build?buildargs=...`), so only this
    /// part goes to the log.
    static func logTarget(_ requestLine: String) -> String {
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return parts.first.map { String($0.prefix(16)) } ?? "" }
        return "\(parts[0]) \(parts[1].split(separator: "?", maxSplits: 1).first ?? "")"
    }

    /// Whether an HTTP request line starts long-running work on the daemon.
    static func isWork(_ requestLine: String) -> Bool {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let method = parts[0]
        var path = String(parts[1].split(separator: "?").first ?? "")
        // Drop the API version prefix: /v1.54/build -> /build
        if path.hasPrefix("/v"), let slash = path.dropFirst().firstIndex(of: "/") { path = String(path[slash...]) }
        if path == "/session" || path.hasPrefix("/grpc") { return true }  // BuildKit
        guard method == "POST" || method == "GET" else { return false }
        // docker save
        if method == "GET" { return path == "/images/get" || (path.hasPrefix("/images/") && path.hasSuffix("/get")) }
        return path == "/build" || path == "/images/create" || path == "/images/load" || path == "/commit"
            || (path.hasPrefix("/images/") && path.hasSuffix("/push"))
    }
}
