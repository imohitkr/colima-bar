import Foundation

/// Parses Docker's RFC 3339 timestamps by hand. ISO8601DateFormatter costs
/// about 50 µs per line, which blocks the main thread at high log rates.
enum LogTime {
    /// Returns UNIX seconds and nanoseconds for "YYYY-MM-DDTHH:MM:SS[.f]Z".
    /// Accepts 0 to 9 fractional digits (more are cut) and a "Z" or
    /// "±HH:MM" zone. Returns nil for anything else.
    static func parse(_ ts: Substring) -> (secs: Int64, nanos: Int64)? {
        if let r = ts.utf8.withContiguousStorageIfAvailable({ parse($0) }) { return r }
        return Array(ts.utf8).withUnsafeBufferPointer { parse($0) }
    }

    private static func parse(_ b: UnsafeBufferPointer<UInt8>) -> (secs: Int64, nanos: Int64)? {
        guard b.count >= 20 else { return nil }
        func num(_ at: Int, _ len: Int) -> Int? {
            var v = 0
            for i in at..<(at + len) {
                let d = Int(b[i]) &- 48
                guard d >= 0, d <= 9 else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let y = num(0, 4), b[4] == 0x2D, let mo = num(5, 2), b[7] == 0x2D, let d = num(8, 2),
            b[10] == 0x54 || b[10] == 0x74,  // "T" or "t"
            let h = num(11, 2), b[13] == 0x3A, let mi = num(14, 2), b[16] == 0x3A, let s = num(17, 2),
            (1...12).contains(mo), d >= 1, d <= daysIn(month: mo, year: y),
            h <= 23, mi <= 59, s <= 60
        else { return nil }
        var i = 19
        var nanos = 0
        if b[i] == 0x2E {  // "."
            i += 1
            var digits = 0
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                if digits < 9 {
                    nanos = nanos * 10 + Int(b[i] - 0x30)
                    digits += 1
                }
                i += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<9 { nanos *= 10 }
        }
        guard i < b.count else { return nil }
        var offset = 0
        if b[i] == 0x5A || b[i] == 0x7A {  // "Z" or "z"
            i += 1
        } else if b[i] == 0x2B || b[i] == 0x2D {  // "+" or "-"
            guard i + 6 == b.count, let oh = num(i + 1, 2), b[i + 3] == 0x3A, let om = num(i + 4, 2),
                oh <= 23, om <= 59
            else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == 0x2B ? 1 : -1)
            i += 6
        } else {
            return nil
        }
        guard i == b.count else { return nil }
        let secs = daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s - offset
        return (Int64(secs), Int64(nanos))
    }

    private static func daysIn(month m: Int, year y: Int) -> Int {
        switch m {
        case 2: return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    /// This is Howard Hinnant's `days_from_civil` algorithm.
    private static func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Formats the time as HH:mm:ss.SSS in local time. It cuts (does not
    /// round) the nanoseconds to milliseconds.
    static func clock(secs: Int64, nanos: Int64) -> String {
        var t = time_t(secs)
        var parts = tm()
        guard localtime_r(&t, &parts) != nil else { return "" }
        let ms = Int(nanos / 1_000_000)
        return String(unsafeUninitializedCapacity: 12) { p in
            func put2(_ at: Int, _ v: Int) {
                p[at] = UInt8(48 + v / 10)
                p[at + 1] = UInt8(48 + v % 10)
            }
            put2(0, Int(parts.tm_hour))
            p[2] = 0x3A
            put2(3, Int(parts.tm_min))
            p[5] = 0x3A
            put2(6, Int(parts.tm_sec))
            p[8] = 0x2E
            p[9] = UInt8(48 + ms / 100)
            put2(10, ms % 100)
            return 12
        }
    }
}
