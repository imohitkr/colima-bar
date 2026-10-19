import Darwin
import Foundation

/// Asks the system resolver of the Mac for the IPv4 address of a host name.
/// `getaddrinfo` has no time limit, so it runs on its own thread, and
/// `Deadline` ends the wait. A stuck lookup leaves one idle thread behind.
enum HostLookup {
    /// True if the Mac resolves `host`. False if it does not, or if the
    /// lookup takes longer than `seconds`.
    static func resolves(_ host: String, seconds: TimeInterval = 5) async -> Bool {
        await Deadline.run(seconds: seconds, fallback: false) {
            await withCheckedContinuation { cont in
                Thread.detachNewThread { cont.resume(returning: resolvesSync(host)) }
            }
        }
    }

    /// The blocking lookup. Call it off the main thread only.
    static func resolvesSync(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return false }
        defer { freeaddrinfo(result) }
        return result != nil
    }
}
