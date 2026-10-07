import Foundation

/// The newest log lines of one container that `RemovedLogKeeper` watches.
/// The stream reader thread feeds raw bytes. The ring splits the frames,
/// parses the lines and keeps at most `maxLines` lines and `maxBytes` bytes
/// of text. It drops the oldest lines first. It never writes to disk.
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class RemovedLogRing: @unchecked Sendable {
    let maxLines: Int
    let maxBytes: Int
    private let lock = NSLock()
    private var demux = LogDemuxer(tty: false)
    private var lines: [LogLine] = []
    private var bytes = 0
    private var nextID = 0

    init(maxLines: Int, maxBytes: Int) {
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }

    /// Sets the frame format before the first `feed`. A TTY container sends
    /// raw text, the others send stdout and stderr frames.
    func setTTY(_ tty: Bool) {
        lock.withLock { demux = LogDemuxer(tty: tty) }
    }

    /// Splits and parses one read of the log stream, on the reader thread.
    func feed(_ data: Data) {
        lock.withLock {
            let pieces = demux.feed(data)
            append(pieces.map { LogLine.parse($0.text, isStderr: $0.isStderr).line })
        }
    }

    /// Adds parsed lines. `feed` uses it, and tests call it directly.
    func push(_ new: [LogLine]) {
        lock.withLock { append(new) }
    }

    /// A copy of the kept lines, oldest first.
    var snapshot: [LogLine] { lock.withLock { lines } }

    /// Bytes of text in the kept lines.
    var textBytes: Int { lock.withLock { bytes } }

    /// Call with the lock held.
    private func append(_ new: [LogLine]) {
        guard !new.isEmpty else { return }
        for var l in new {
            l.id = nextID
            nextID += 1
            bytes += LogTrim.size(l)
            lines.append(l)
        }
        // At most `maxLines` (500) lines, so each trim moves few elements.
        let d = LogTrim.dropCount(lines, bytes: bytes, maxLines: maxLines, maxBytes: maxBytes)
        guard d.count > 0 else { return }
        lines.removeFirst(d.count)
        bytes -= d.bytes
    }
}
