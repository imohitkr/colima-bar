import Foundation

/// Docker multiplexes stdout/stderr of non-TTY containers into frames:
/// [stream(1), 0, 0, 0, size(4, big-endian)] + payload. TTY containers send
/// raw text. Keeps partial lines per stream between reads as raw bytes, so a
/// UTF-8 character split across reads or frames stays intact.
struct LogDemuxer {
    /// Longer lines are split into pieces of this size, so a stream that
    /// never sends "\n" cannot grow the partial buffer without limit.
    static let maxLineBytes = 16 * 1024
    /// Ends each piece of a split line except the last.
    static let splitMarker = " [continues]"

    let tty: Bool
    private var buffer = Data()
    private var partial: [Bool: Data] = [false: Data(), true: Data()]

    init(tty: Bool) { self.tty = tty }

    /// Returns complete lines as (text, isStderr).
    mutating func feed(_ data: Data) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        if tty {
            split(data, stderr: false, into: &out)
            return out
        }
        buffer.append(data)
        // Remove the used frames once at the end. Removing each frame from
        // the front would move the rest of the buffer every time.
        var b = buffer.startIndex
        while buffer.endIndex - b >= 8 {
            let size =
                Int(buffer[b + 4]) << 24 | Int(buffer[b + 5]) << 16 | Int(buffer[b + 6]) << 8 | Int(buffer[b + 7])
            guard buffer.endIndex - b >= 8 + size else { break }
            let payload = buffer[(b + 8)..<(b + 8 + size)]
            let isErr = buffer[b] == 2
            split(payload, stderr: isErr, into: &out)
            b += 8 + size
        }
        buffer.removeSubrange(buffer.startIndex..<b)
        return out
    }

    /// Splits on "\n" at the byte level and decodes only whole lines.
    private mutating func split(_ bytes: Data, stderr: Bool, into out: inout [(String, Bool)]) {
        var pending = partial[stderr] ?? Data()
        partial[stderr] = nil  // so the append below does not copy
        pending.append(bytes)
        var start = pending.startIndex
        while let nl = pending[start...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, pending[end - 1] == 0x0D { end -= 1 }  // drop "\r"
            start = Self.cutLong(pending, from: start, to: end, stderr: stderr, into: &out)
            out.append((String(decoding: pending[start..<end], as: UTF8.self), stderr))
            start = nl + 1
        }
        start = Self.cutLong(pending, from: start, to: pending.endIndex, stderr: stderr, into: &out)
        partial[stderr] = Data(pending[start...])
    }

    /// Emits full-size pieces while more than `maxLineBytes` remain, and
    /// returns where the rest starts. Never cuts inside a UTF-8 character.
    private static func cutLong(
        _ d: Data, from: Int, to end: Int, stderr: Bool,
        into out: inout [(String, Bool)]
    ) -> Int {
        var start = from
        while end - start > maxLineBytes {
            var cut = start + maxLineBytes
            while cut > start + 1, d[cut] & 0xC0 == 0x80 { cut -= 1 }  // continuation byte
            out.append((String(decoding: d[start..<cut], as: UTF8.self) + splitMarker, stderr))
            start = cut
        }
        return start
    }
}
