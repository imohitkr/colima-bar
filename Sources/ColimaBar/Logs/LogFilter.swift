import Foundation

/// Case-insensitive search as a byte scan, without a stored lower-case copy
/// of each line (that copy doubled the memory per line). It folds A-Z to
/// a-z into a reused scratch buffer and runs memmem on it. Other bytes
/// compare exactly. When the query has non-ASCII letters and the plain scan
/// fails, it lower-cases the line, as the filter did before, so "ÄPFEL"
/// still matches "äpfel".
enum LogFilter {
    static func needle(_ query: String) -> [UInt8] { Array(query.lowercased().utf8) }

    /// Checks one line. Use a `Matcher` to check many lines with one query.
    static func contains(_ text: String, _ needle: [UInt8]) -> Bool {
        var m = Matcher(needle: needle)
        return m.matches(text)
    }

    /// The UTF-8 forms of the scalars whose lower case contains the first
    /// non-ASCII scalar of `needle` (a lower-cased query), and of that scalar
    /// itself. String.lowercased() maps each scalar on its own, so a line
    /// whose lower case contains the needle has one of these. Empty if the
    /// needle is ASCII.
    static func prefilter(_ needle: String) -> [[UInt8]] {
        let scalars = needle.unicodeScalars.filter { !$0.isASCII }
        guard let c = scalars.first(where: { $0.properties.isCased }) ?? scalars.first else { return [] }
        return ([c] + (lowerSources[c] ?? [])).map { Array(String($0).utf8) }
    }

    /// For each non-ASCII scalar, the scalars whose lower case contains it
    /// ("å" <- "Å", "Å" (Angstrom sign)). Built once, on the first non-ASCII
    /// query. Planes 2 and up have no cased letters (a test checks this).
    static let lowerSources: [Unicode.Scalar: [Unicode.Scalar]] = {
        var out: [Unicode.Scalar: [Unicode.Scalar]] = [:]
        for v in UInt32(0x80)..<0x20000 {
            guard let s = Unicode.Scalar(v), s.properties.changesWhenLowercased else { continue }
            for l in s.properties.lowercaseMapping.unicodeScalars where !l.isASCII { out[l, default: []].append(s) }
        }
        return out
    }()

    /// Holds the query and a scratch buffer for many lines. Not thread-safe.
    struct Matcher {
        let needle: [UInt8]
        private let needleASCII: Bool  // false if the query has non-ASCII cased letters
        /// For the slow path: the UTF-8 forms of every letter that lower-cases
        /// to the query's first non-ASCII letter. A line with none of them
        /// can't match, so it is not lower-cased.
        private let prefilter: [[UInt8]]
        private var scratch: [UInt8] = []

        init(query: String) { self.init(needle: LogFilter.needle(query)) }

        init(needle: [UInt8]) {
            self.needle = needle
            let text = String(decoding: needle, as: UTF8.self)
            // Only letters with an upper and a lower case need the slow path.
            // Emoji, CJK and symbols in the query do not.
            needleASCII = !text.contains {
                !$0.isASCII && $0.lowercased() != $0.uppercased()
            }
            prefilter = needleASCII ? [] : LogFilter.prefilter(text)
        }

        mutating func matches(_ text: String) -> Bool {
            if needle.isEmpty { return true }
            var hay = text
            if let r = hay.utf8.withContiguousStorageIfAvailable({ scan($0) }) { return r }
            hay.makeContiguousUTF8()
            return hay.utf8.withContiguousStorageIfAvailable { scan($0) } ?? false
        }

        private mutating func scan(_ hay: UnsafeBufferPointer<UInt8>) -> Bool {
            // Lower-casing can make a line longer ("İ" becomes "i" and a
            // combining dot), so a short line can still match on the slow path.
            guard hay.count >= needle.count || !needleASCII else { return false }
            if scratch.count < hay.count { scratch = [UInt8](repeating: 0, count: max(hay.count, 256)) }
            let found = scratch.withUnsafeMutableBufferPointer { out in
                Self.fold(hay, into: out)
                return needle.withUnsafeBufferPointer { n in
                    memmem(out.baseAddress, hay.count, n.baseAddress, n.count) != nil
                }
            }
            if found || needleASCII { return found }
            // Only ASCII bytes change above. Lower-case non-ASCII letters too,
            // but only for lines that have non-ASCII bytes and one of the
            // prefilter letters.
            guard hay.contains(where: { $0 >= 0x80 }) else { return false }
            if !prefilter.isEmpty,
                !prefilter.contains(where: { p in
                    p.withUnsafeBufferPointer { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
                })
            {
                return false
            }
            let lower = Array(String(decoding: hay, as: UTF8.self).lowercased().utf8)
            return lower.withUnsafeBufferPointer { l in
                needle.withUnsafeBufferPointer { n in
                    memmem(l.baseAddress, l.count, n.baseAddress, n.count) != nil
                }
            }
        }

        /// Copies `hay` to `out` with A-Z changed to a-z. It works on 8 bytes
        /// at a time: for each byte below 0x80 it tests "A" <= b <= "Z" with
        /// one addition per bound and sets bit 0x20 where both hold.
        static func fold(_ hay: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>) {
            guard let src = hay.baseAddress, let dst = out.baseAddress else { return }
            let ones: UInt64 = 0x0101_0101_0101_0101
            let high = ones &* 0x80
            let n = hay.count
            var i = 0
            while i + 8 <= n {
                let x = UnsafeRawPointer(src + i).loadUnaligned(as: UInt64.self)
                let low7 = x & ~high
                let atLeastA = (low7 &+ ones &* (0x80 - 0x41)) & high
                let pastZ = (low7 &+ ones &* (0x80 - 0x5B)) & high
                let upper = atLeastA & ~pastZ & ~x
                UnsafeMutableRawPointer(dst + i).storeBytes(of: x | (upper >> 2), as: UInt64.self)
                i += 8
            }
            while i < n {
                let b = src[i]
                dst[i] = b | (b &- 0x41 < 26 ? 0x20 : 0)
                i += 1
            }
        }
    }
}
