import Darwin
import Foundation

/// The per-process limit on open files (RLIMIT_NOFILE).
enum FileLimit {
    /// The proxy uses 2 fds per spliced connection, and each stats stream
    /// and log window uses 1 more. launchd starts apps with a soft limit of
    /// 256, which a busy dashboard and a few IDE clients can reach.
    static let wanted: rlim_t = 8192

    /// Raises the soft limit to `target`, capped by the hard limit and
    /// OPEN_MAX. It never lowers the limit. Returns the soft limit after
    /// the call.
    @discardableResult
    static func raise(to target: rlim_t = wanted) -> rlim_t {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return 0 }
        // macOS refuses RLIM_INFINITY and values above OPEN_MAX here.
        var want = min(target, lim.rlim_max, rlim_t(OPEN_MAX))
        guard want > lim.rlim_cur else { return lim.rlim_cur }
        var next = lim
        next.rlim_cur = want
        if setrlimit(RLIMIT_NOFILE, &next) != 0 {
            // kern.maxfilesperproc can be lower than OPEN_MAX: try that.
            var perProc: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("kern.maxfilesperproc", &perProc, &size, nil, 0) == 0, perProc > 0 {
                want = min(want, rlim_t(perProc))
                next.rlim_cur = want
                if want > lim.rlim_cur { setrlimit(RLIMIT_NOFILE, &next) }
            }
        }
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return 0 }
        return lim.rlim_cur
    }
}
