import Testing

@testable import ColimaBar

@Suite struct DomainSuffixTests {
    @Test(arguments: ["test", "colima.internal", "dev.test", "a.b.test", "lab.home.arpa", "x.y.internal", "a-b.test"])
    func acceptsReservedSuffixes(_ s: String) {
        #expect(DomainSuffix.problem(s) == nil)
    }

    @Test func rejectsWithTheExactMessage() {
        let table: [(String, String)] = [
            ("", "Type a suffix, for example colima.internal."),
            ("  . ", "Type a suffix, for example colima.internal."),
            ("a_b.test", "Use lower-case letters, digits, hyphens and dots."),
            ("é.test", "Use lower-case letters, digits, hyphens and dots."),
            ("a b.test", "Use lower-case letters, digits, hyphens and dots."),
            ("a.b.c.d.test", "Use at most 4 parts and 100 characters."),
            (
                String(repeating: "a", count: 50) + "." + String(repeating: "b", count: 50) + ".test",
                "Use at most 4 parts and 100 characters."
            ),
            ("a..test", "Each part must start and end with a letter or a digit."),
            ("-a.test", "Each part must start and end with a letter or a digit."),
            ("a-.test", "Each part must start and end with a letter or a digit."),
            (String(repeating: "a", count: 64) + ".test", "Each part must start and end with a letter or a digit."),
            ("localhost", "localhost works already. Choose another suffix."),
            ("x.localhost", "localhost works already. Choose another suffix."),
            ("local", ".local does not work: macOS sends .local names to multicast DNS."),
            ("foo.local", ".local does not work: macOS sends .local names to multicast DNS."),
            ("internal", "End the suffix with .test, .internal or .home.arpa, or use test."),
            ("home.arpa", "End the suffix with .test, .internal or .home.arpa, or use test."),
            ("dev", "End the suffix with .test, .internal or .home.arpa, or use test."),
            ("com", "End the suffix with .test, .internal or .home.arpa, or use test."),
            ("example.com", "End the suffix with .test, .internal or .home.arpa, or use test."),
            ("arpa", "End the suffix with .test, .internal or .home.arpa, or use test."),
            ("test.com", "End the suffix with .test, .internal or .home.arpa, or use test."),
        ]
        for (raw, message) in table { #expect(DomainSuffix.problem(raw) == message, "\(raw)") }
    }

    @Test func aHundredBytesPassAndOneMoreFails() {
        // 4 labels of at most 63 bytes: 24 + 1 + 24 + 1 + 24 + 1 + 4 = 79 bytes is fine.
        let ok = ["a", "b", "c"].map { String(repeating: $0, count: 24) }.joined(separator: ".") + ".test"
        #expect(DomainSuffix.problem(ok) == nil)
        let long = String(repeating: "a", count: 60) + "." + String(repeating: "b", count: 41) + ".test"
        #expect(long.utf8.count > 100)
        #expect(DomainSuffix.problem(long) == "Use at most 4 parts and 100 characters.")
    }

    @Test func normalizesCaseSpacesAndDots() {
        #expect(DomainSuffix.normalized("  UPPER.Test. ") == "upper.test")
        #expect(DomainSuffix.normalized(".colima.internal") == "colima.internal")
        #expect(DomainSuffix.problem("UPPER.test") == nil)
        #expect(DomainSuffix.valid("UPPER.test") == "upper.test")
        #expect(DomainSuffix.valid("dev") == nil)
    }

    @Test func noPublicSuffixPasses() {
        for tld in ["com", "org", "net", "dev", "app", "io", "de", "in", "arpa", "example"] {
            #expect(DomainSuffix.problem(tld) != nil)
            #expect(DomainSuffix.problem("shop.\(tld)") != nil)
        }
    }

    @Test func theDefaultIsValid() {
        #expect(DomainSuffix.problem(DomainSuffix.defaultValue) == nil)
    }
}
