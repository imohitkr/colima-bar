import Foundation
import Testing

@testable import ColimaBar

@Suite struct LogFilterTests {
    /// Checks one line. LogFilter.contains uses a Matcher.
    private func has(_ text: String, _ query: String) -> Bool {
        LogFilter.contains(text, LogFilter.needle(query))
    }

    /// The reference implementation, which the filter used before: lower-case
    /// both sides, then compare bytes.
    private func reference(_ text: String, _ query: String) -> Bool {
        let n = Array(query.lowercased().utf8)
        return n.isEmpty
            || Array(text.lowercased().utf8).withUnsafeBufferPointer { h in
                n.withUnsafeBufferPointer { memmem(h.baseAddress, h.count, $0.baseAddress, $0.count) != nil }
            }
    }

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
        let cased = String(decoding: needle, as: UTF8.self).contains {
            !$0.isASCII && $0.lowercased() != $0.uppercased()
        }
        guard cased, text.utf8.contains(where: { $0 >= 0x80 }) else { return false }
        return has(Array(text.lowercased().utf8))
    }

    @Test func edgeCases() {
        #expect(has("anything", ""))
        #expect(has("", ""))
        #expect(!has("", "a"))
        #expect(!has("ab", "abc"))
        #expect(has(String(repeating: "x", count: 10_000) + "Needle", "needle"))
    }

    @Test func foldsASCIIOnTheRawText() {
        #expect(has("Connection REFUSED by Upstream", "refused"))
        #expect(has("Connection REFUSED by Upstream", "UPSTREAM"))
        #expect(has("[@`{] brackets", "[@`{]"))  // bytes next to A-Z and a-z do not fold
        #expect(!has("[@`{]", "{`@["))
        #expect(!has("abc", "abd"))
        #expect(has("connection refused", "REFUSED"))
        #expect(has("short", "SHORT"))
        #expect(!has("connection refused", "accepted"))
    }

    @Test func nonASCIIMatchesAsBefore() {
        #expect(has("ÄPFEL und Birnen", "äpfel"))
        #expect(has("äpfel", "ÄPFEL"))
        #expect(has("Grüße aus KÖLN", "köln"))
        #expect(has("Fehler: Datei FEHLT – Größe 0", "größe 0"))
        #expect(has("日本語のログ 🚀 DONE", "🚀 done"))
        #expect(has("日本語のログ 🚀 done", "🚀 DONE"))
        #expect(has("Grüße aus Köln ✓", "KÖLN"))
        #expect(!has("Grüße", "GRÜSSE"))  // no full case folding, as before
        #expect(!has("Köln", "koln"))
        #expect(!has("ÁRBOL", "árboles"))
    }

    @Test func scratchFromALongLineDoesNotLeak() {
        var m = LogFilter.Matcher(query: "needle")
        let got = [String(repeating: "x", count: 5000) + "NEEDLE", "need", "xneedl", "a needle"].map { m.matches($0) }
        #expect(got == [true, false, false, true])
    }

    @Test func matchesReferenceImplementation() {
        let alphabet = Array("aAbBzZ09 _-:[`{@ÄäÖößé🚀")
        var rng = SystemRandomNumberGenerator()
        func word(_ n: Int) -> String { String((0..<n).map { _ in alphabet.randomElement(using: &rng)! }) }
        for _ in 0..<3000 {
            let text = word(Int.random(in: 0...40, using: &rng))
            let query =
                Bool.random(using: &rng) && text.count > 2
                ? String(text.dropFirst(Int.random(in: 0...2, using: &rng)).prefix(Int.random(in: 1...6, using: &rng)))
                    .uppercased()
                : word(Int.random(in: 1...3, using: &rng))
            #expect(has(text, query) == reference(text, query), "\(text) / \(query)")
        }
    }

    @Test(.benchmark) func filtersTwentyThousandLinesQuickly() {
        let lines = (0..<20_000).map {
            "2026-10-06 INFO worker-\($0 % 64) handled GET /api/v1/items/\($0) in \($0 % 900) ms"
        }
        var m = LogFilter.Matcher(query: "ERROR timeout")
        var hits = 0
        let best = bestTime(runs: 5) {
            hits = 0
            for l in lines where m.matches(l) { hits += 1 }
        }
        #expect(hits == 0)
        // About 0.9 ms in a release build (the same as the old filter on a
        // stored lower-case copy) and 5-15 ms in a debug build. The bound is
        // generous, so slow CI under load does not fail.
        #expect(best < .seconds(1), "\(best)")
    }

    @Test func randomLinesMatchTheSlowPath() {
        let alphabet: [String] = [
            "a", "B", "k", "K", "s", "S", "i", "I", " ", ":", "ä", "Ä", "å", "Å", "\u{212B}",
            "ß", "\u{1E9E}", "σ", "Σ", "ς", "ω", "\u{2126}", "\u{212A}", "İ", "ı", "\u{0307}",
            "é", "É", "e\u{0301}", "ǅ", "ǆ", "Ǆ", "日", "🚀", "ж", "Ж",
        ]
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
        #expect(has("unit: 5 \u{212B}", "å"))  // Angstrom sign lower-cases to å
        #expect(has("Gruß \u{1E9E}", "ẞ"))  // capital sharp s
        #expect(has("R = 4 \u{2126}", "ω"))  // Ohm sign
        #expect(!has("plain ascii line", "ä"))
        #expect(has("İ", "İ"))  // the lower case is longer than the line
    }

    @Test func noCasedLettersAbovePlaneOne() {
        // LogFilter.lowerSources scans only planes 0 and 1.
        for v in UInt32(0x20000)...0x10FFFF {
            guard let s = Unicode.Scalar(v) else { continue }
            #expect(!s.properties.changesWhenLowercased, "\(String(v, radix: 16))")
            if s.properties.changesWhenLowercased { break }
        }
    }

    @Test(.benchmark) func prefilterKeepsSlowPathFast() {
        // 20k lines of 1.5 KB non-ASCII text with no match.
        let line = String(repeating: "Grüße aus Köln, ", count: 90)
        var m = LogFilter.Matcher(query: "ÄPFEL")
        var hits = 0
        let best = bestTime {
            hits = 0
            for _ in 0..<20_000 where m.matches(line) { hits += 1 }
        }
        #expect(hits == 0)
        // About 150 ms in a debug build. The full lower-casing took about
        // 570 ms in a release build. The best of 3 runs keeps the bound
        // stable while other suites run in parallel.
        #expect(best < .milliseconds(400), "\(best)")
    }
}
