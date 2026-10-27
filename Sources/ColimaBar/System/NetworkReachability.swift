import Foundation
import Network
import os

/// Whether the Mac has a route to the internet. It reads the first path that
/// the system reports. It sends no packet and needs no permission.
enum NetworkReachability {
    /// How long to wait for the system (seconds).
    static let timeout: TimeInterval = 2

    /// False if the system says that no network route exists. If the system
    /// does not answer in time, it says true: a wrong "online" only lets the
    /// scanner try and fail.
    static func isOnline() async -> Bool {
        let monitor = NWPathMonitor()
        let answered = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            @Sendable func finish(_ online: Bool) {
                guard
                    answered.withLock({ done in
                        defer { done = true }
                        return !done
                    })
                else { return }
                // The handler holds `finish`, and `finish` holds the monitor.
                // Without this line, that cycle keeps the monitor alive.
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                cont.resume(returning: online)
            }
            monitor.pathUpdateHandler = { finish($0.status == .satisfied) }
            let queue = DispatchQueue(label: "colimabar.reachability")
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(true) }
        }
    }
}
