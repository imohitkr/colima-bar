import Foundation
import Testing
@testable import ColimaBar

@Suite struct LogFilterPrefilterTests {
    /// The filter without the prefilter: an ASCII-folded scan, then, for a
    /// query with non-ASCII cased letters, a lower-cased copy of the line.
    private func slow(_ text: String, _ query: String) -> Bool {
        let needle = LogFilter.needle(query)
        if needle.isEmpty { return true }
        func has(_ hay: [UInt8]) -> Bool {
            guard hay.count >= needle.count else { return false }
            return (0...(hay.count - needle.count)).contains { i in hay[i..<(i + needle.count)].elementsEqual(needle) }
        }
        let folded = text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        if has(folded) { return true }
        let cased = String(decoding: needle, as: UTF8.self).contains { !$0.isASCII && $0.lowercased() != $0.uppercased() }
        guard cased, text.utf8.contains(where: { $0 >= 0x80 }) else { return false }
        return has(Array(text.lowercased().utf8))
    }

    @Test func randomLinesMatchTheSlowPath() {
        let alphabet: [String] = ["a", "B", "k", "K", "s", "S", "i", "I", " ", ":", "ä", "Ä", "å", "Å", "\u{212B}",
                                  "ß", "\u{1E9E}", "σ", "Σ", "ς", "ω", "\u{2126}", "\u{212A}", "İ", "ı", "\u{0307}",
                                  "é", "É", "e\u{0301}", "ǅ", "ǆ", "Ǆ", "日", "🚀", "ж", "Ж"]
        var rng = SystemRandomNumberGenerator()
        func random(_ n: Int) -> String { (0..<n).map { _ in alphabet.randomElement(using: &rng)! }.joined() }
        var checked = 0
        for _ in 0..<300 {
            let query = random(Int.random(in: 1...3, using: &rng))
            var m = LogFilter.Matcher(query: query)
            for _ in 0..<40 {
                let line = random(Int.random(in: 0...24, using: &rng))
                let expected = slow(line, query)
                let got = m.matches(line)
                #expect(got == expected, "query \(query.debugDescription) line \(line.debugDescription)")
                checked += 1
            }
        }
        #expect(checked == 12_000)
    }

    @Test func specialLowerCaseSources() {
        func has(_ text: String, _ query: String) -> Bool { LogFilter.contains(text, LogFilter.needle(query)) }
        #expect(has("unit: 5 \u{212B}", "å"))       // Angstrom sign lower-cases to å
        #expect(has("Gruß \u{1E9E}", "ẞ"))           // capital sharp s
        #expect(has("R = 4 \u{2126}", "ω"))          // Ohm sign
        #expect(!has("plain ascii line", "ä"))
        #expect(has("İ", "İ"))                       // the lower case is longer than the line
    }

    @Test func noCasedLettersAbovePlaneOne() {
        // LogFilter.lowerSources scans only planes 0 and 1.
        for v in UInt32(0x20000)...0x10FFFF {
            guard let s = Unicode.Scalar(v) else { continue }
            #expect(!s.properties.changesWhenLowercased, "\(String(v, radix: 16))")
            if s.properties.changesWhenLowercased { break }
        }
    }

    @Test func prefilterKeepsSlowPathFast() {
        // 20k lines of 1.5 KB non-ASCII text with no match.
        let line = String(repeating: "Grüße aus Köln, ", count: 90)
        var m = LogFilter.Matcher(query: "ÄPFEL")
        let start = ContinuousClock.now
        var hits = 0
        for _ in 0..<20_000 where m.matches(line) { hits += 1 }
        let elapsed = ContinuousClock.now - start
        #expect(hits == 0)
        // The full lower-casing took about 570 ms in a release build. The
        // bound is generous, so slow CI does not fail.
        #expect(elapsed < .milliseconds(400), "\(elapsed)")
    }
}
