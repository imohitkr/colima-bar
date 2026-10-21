import Darwin
import Foundation

/// Asks the system resolver (the path that browsers and `curl` use, and the
/// one that reads `/etc/resolver`) for a name.
enum LoopbackLookup {
    /// True when `getaddrinfo` gives 127.0.0.1 for `name` within `timeout`.
    /// A lookup that hangs keeps its thread but no longer holds the caller.
    static func resolvesToLoopback(_ name: String, timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = NSLock()
            nonisolated(unsafe) var resumed = false
            @Sendable func finish(_ value: Bool) {
                let first = once.withLock { () -> Bool in
                    defer { resumed = true }
                    return !resumed
                }
                if first { cont.resume(returning: value) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
            Thread.detachNewThread { finish(lookup(name)) }
        }
    }

    private static func lookup(_ name: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let address = current.pointee.ai_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                let loopback = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr) == 0x7F00_0001
                }
                if loopback { return true }
            }
            node = current.pointee.ai_next
        }
        return false
    }
}
