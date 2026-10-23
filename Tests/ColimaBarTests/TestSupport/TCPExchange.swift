import Darwin
import Foundation

/// A blocking TCP client on 127.0.0.1 for raw bytes. Call its methods on their
/// own thread (see `onOwnThread`), never on a Swift concurrency thread.
/// `@unchecked Sendable`: the descriptor never changes.
final class TCPClient: @unchecked Sendable {
    private let fd: Int32

    /// nil when the connect fails. With `ipv6`, it connects to ::1.
    init?(port: Int, ipv6: Bool = false) {
        let s = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        let rc: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard rc == 0 else {
            close(s)
            return nil
        }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
    }

    deinit { close(fd) }

    @discardableResult
    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Sends the end of the stream, and keeps the read side open.
    func shutdownWrite() { shutdown(fd, SHUT_WR) }

    /// Reads until `until` is in the text, the stream ends or `timeout` seconds pass.
    /// The 30 s is a liveness limit (a stalled CI runner freezes the process for ~18 s).
    func read(until marker: String? = nil, timeout: TimeInterval = 30) -> String {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        let end = Date().addingTimeInterval(timeout)
        while true {
            if let marker, String(decoding: out, as: UTF8.self).contains(marker) { break }
            let left = end.timeIntervalSinceNow
            if left <= 0 { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(left, 1) * 1000))
            if ready < 0, errno != EINTR { break }
            if ready <= 0 { continue }
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Connects to 127.0.0.1:`port` (::1 with `ipv6`), sends the chunks and returns what the server
/// sends back until `until` appears, the stream ends or `timeout` seconds pass.
/// With `halfClose`, it sends the end of the stream after the chunks.
func tcpExchange(
    port: Int, ipv6: Bool = false, send chunks: [Data], until marker: String? = nil, halfClose: Bool = false,
    timeout: TimeInterval = 30
) async -> String {
    await onOwnThread {
        guard let client = TCPClient(port: port, ipv6: ipv6) else { return "<no connect>" }
        for chunk in chunks { client.send(chunk) }
        if halfClose { client.shutdownWrite() }
        return client.read(until: marker, timeout: timeout)
    }
}

/// A GET request for `host` and `path`.
func httpGet(_ host: String, _ path: String = "/") -> Data {
    Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)
}
