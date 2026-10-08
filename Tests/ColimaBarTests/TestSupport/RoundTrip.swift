import Darwin
import Foundation

@testable import ColimaBar

/// Sends raw HTTP over a unix socket and returns everything read until close
/// or until `until` appears. The socket calls block, so they run on their own
/// thread (see onOwnThread). A read that waits more than 20 s ends the call.
func roundTrip(_ path: String, _ request: String, until: String? = nil) async -> String {
    await onOwnThread {
        guard let fd = UnixSocket.connect(path, timeout: 20) else { return "<no connect>" }
        defer { close(fd) }
        _ = UnixSocket.writeAll(fd, Data(request.utf8))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            if let until, String(decoding: out, as: UTF8.self).contains(until) { break }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
