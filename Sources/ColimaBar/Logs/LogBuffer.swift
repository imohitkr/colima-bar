import Foundation

/// Parsed lines wait here between the reader thread and the next flush on
/// the main thread. It keeps at most `cap` lines and `byteCap` bytes of text
/// and drops the oldest, so a slow main thread or a hidden window cannot
/// make memory grow without limit.
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class LogBuffer: @unchecked Sendable {
    let cap: Int
    let byteCap: Int
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var bytes = 0
    private var nextID = 0
    private var last: String?
    private var flushPending = false

    init(cap: Int, byteCap: Int = LogLimits.maxBytes) {
        self.cap = cap
        self.byteCap = byteCap
    }

    /// Gives the lines their ids and stores them. Returns true when the
    /// caller must schedule a flush; one is already pending otherwise.
    func push(_ new: [LogLine], lastTimestamp: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lines.reserveCapacity(lines.count + new.count)
        for var l in new {
            l.id = nextID
            nextID += 1
            bytes += LogTrim.size(l)
            lines.append(l)
        }
        if let lastTimestamp { last = lastTimestamp }
        // Trim in batches, so each push does not move every line.
        if LogLimits.needsTrim(lines: lines.count, bytes: bytes, maxLines: cap, maxBytes: byteCap) { trim() }
        guard !flushPending, !lines.isEmpty else { return false }
        flushPending = true
        return true
    }

    /// Takes all waiting lines (at most `cap`) and allows the next flush.
    func drain() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        flushPending = false
        trim()
        let out = lines
        lines = []
        bytes = 0
        return out
    }

    /// Call with the lock held.
    private func trim() {
        let d = LogTrim.dropCount(lines, bytes: bytes, maxLines: cap, maxBytes: byteCap)
        guard d.count > 0 else { return }
        lines.removeFirst(d.count)
        bytes -= d.bytes
    }

    /// The timestamp of the newest line, as Docker sent it. `since` needs
    /// its full nanosecond precision on reconnect.
    var lastTimestamp: String? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}
