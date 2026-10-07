import Foundation

/// The newest log bytes of one container that `RemovedLogKeeper` watches.
/// The stream reader thread feeds raw reads. The ring copies them into a
/// circular buffer of at most `maxBytes` bytes and drops the oldest whole
/// frames first. It parses nothing while the container runs: `lines()`
/// splits the frames and parses the lines only when a log window opens.
/// It never writes to disk.
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class RemovedLogRing: @unchecked Sendable {
    /// `lines()` returns at most this many of the newest lines.
    let maxLines: Int
    /// The most raw bytes (frame headers and text) that the ring holds.
    let maxBytes: Int
    private let lock = NSLock()
    private var tty = false
    /// The circular buffer. It grows up to `maxBytes`, then wraps.
    private var store: [UInt8] = []
    private var head = 0  // index of the oldest byte in `store`
    private var count = 0
    /// Bytes of a frame larger than the ring that later reads still carry.
    private var skip = 0
    /// TTY only: a drop cut the oldest line, so its start is gone.
    private var cutLine = false

    /// The smallest ring: a frame that starts in the dropped part must have
    /// its whole 8-byte header in the ring or in the new read.
    private static let minBytes = 8

    init(maxLines: Int, maxBytes: Int) {
        self.maxLines = maxLines
        self.maxBytes = max(maxBytes, Self.minBytes)
    }

    /// Sets the frame format before the first `feed`. A TTY container sends
    /// raw text, the others send stdout and stderr frames.
    func setTTY(_ tty: Bool) {
        lock.withLock { self.tty = tty }
    }

    /// Stores one read of the log stream, on the reader thread. The cost is
    /// one copy, and a walk over the headers of the frames that it drops.
    func feed(_ data: Data) {
        lock.withLock {
            var d = data
            if skip > 0 {
                let k = min(skip, d.count)
                d = d.dropFirst(k)
                skip -= k
            }
            guard !d.isEmpty else { return }
            let total = count + d.count
            if total > maxBytes {
                let cut = dropLength(need: total - maxBytes, total: total, incoming: d)
                if tty { cutLine = byte(cut.drop - 1, d) != 0x0A }
                let fromRing = min(cut.drop, count)
                if fromRing > 0 { head = (head + fromRing) % store.count }
                count -= fromRing
                d = d.dropFirst(cut.drop - fromRing)
                skip = cut.skip
            }
            write(d)
        }
    }

    /// The bytes that the ring holds now.
    var rawBytes: Int { lock.withLock { count } }

    /// Splits and parses the kept bytes: at most `maxLines` of the newest
    /// lines, oldest first. A partial last line is left out.
    func lines() -> [LogLine] {
        let (raw, tty, cutLine) = lock.withLock { (linear(), tty, cutLine) }
        var demux = LogDemuxer(tty: tty)
        var pieces = demux.feed(raw)[...]
        if cutLine, !pieces.isEmpty { pieces = pieces.dropFirst() }
        return pieces.suffix(maxLines).enumerated().map { i, p in
            var l = LogLine.parse(p.text, isStderr: p.isStderr).line
            l.id = i
            return l
        }
    }

    // MARK: - Buffer (call with the lock held)

    /// The byte at offset `o` of the ring followed by `d`.
    private func byte(_ o: Int, _ d: Data) -> UInt8 {
        o < count ? store[(head + o) % store.count] : d[d.startIndex + o - count]
    }

    /// How many bytes to drop from the front of the ring followed by `d`,
    /// so that at most `maxBytes` remain. Frames are dropped whole, so the
    /// rest still starts at a frame header. If one frame is larger than the
    /// ring, all bytes go, and `skip` is the rest of that frame in later reads.
    private func dropLength(need: Int, total: Int, incoming d: Data) -> (drop: Int, skip: Int) {
        if tty { return (need, 0) }
        var o = 0
        while o < need {
            // o < total - maxBytes, and maxBytes >= 8: the header is complete.
            let size =
                Int(byte(o + 4, d)) << 24 | Int(byte(o + 5, d)) << 16 | Int(byte(o + 6, d)) << 8
                | Int(byte(o + 7, d))
            let end = o + 8 + size
            if end > total { return (total, end - total) }
            o = end
        }
        return (o, 0)
    }

    /// Appends `d`. The caller made room, so `count + d.count <= maxBytes`.
    private func write(_ d: Data) {
        guard !d.isEmpty else { return }
        if store.count < count + d.count {
            grow(to: min(maxBytes, max(count + d.count, store.count * 2, 4096)))
        }
        let cap = store.count
        var tail = (head + count) % cap
        var src = d.startIndex
        store.withUnsafeMutableBytes { dst in
            while src < d.endIndex {
                let k = min(d.endIndex - src, cap - tail)
                d.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: dst[tail..<(tail + k)]), from: src..<(src + k))
                src += k
                tail = (tail + k) % cap
            }
        }
        count += d.count
    }

    /// Moves the kept bytes to the start of a larger buffer.
    private func grow(to size: Int) {
        let first = min(count, store.count - head)
        var bigger = [UInt8](repeating: 0, count: size)
        bigger.replaceSubrange(0..<first, with: store[head..<(head + first)])
        bigger.replaceSubrange(first..<count, with: store[0..<(count - first)])
        store = bigger
        head = 0
    }

    /// The kept bytes, oldest first.
    private func linear() -> Data {
        guard count > 0 else { return Data() }
        let first = min(count, store.count - head)
        var out = Data(capacity: count)
        out.append(contentsOf: store[head..<(head + first)])
        out.append(contentsOf: store[0..<(count - first)])
        return out
    }
}
