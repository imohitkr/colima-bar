import Foundation

/// Asks the system about one process by its PID.
enum ProcessProbe {
    /// The start time of the process, or nil if no process has the PID.
    static func startTime(pid: Int) -> Date? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0,
            Int(info.kp_proc.p_pid) == pid
        else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    static func isAlive(pid: Int) -> Bool { startTime(pid: pid) != nil }
}
