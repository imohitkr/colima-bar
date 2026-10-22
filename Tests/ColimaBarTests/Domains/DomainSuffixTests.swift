import Testing

@testable import ColimaBar

@Suite struct DomainSuffixTests {
    @Test(arguments: ["test", "colima.internal", "dev.test", "a.b.test", "lab.home.arpa", "x.y.internal", "a-b.test"])
    func acceptsReservedSuffixes(_ s: String) {
        #expect(DomainSuffix.problem(s) == nil)
    }

    private let shape = "Use one or two parts before .test, .internal or .home.arpa. Or use test."

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
            ("internal", shape),
            ("home.arpa", shape),
            ("dev", shape),
            ("com", shape),
            ("example.com", shape),
            ("arpa", shape),
            ("test.com", shape),
            ("a.b.c.test", shape),
            ("a.b.c.internal", shape),
            ("a.b.c.home.arpa", "Use at most 4 parts and 100 characters."),
            ("a\nb.test", "Use lower-case letters, digits, hyphens and dots."),
            ("a\tb.test", "Use lower-case letters, digits, hyphens and dots."),
        ]
        for (raw, message) in table { #expect(DomainSuffix.problem(raw) == message, "\(raw)") }
    }

    @Test func aHundredBytesPassAndOneMoreFails() {
        let label = String(repeating: "a", count: 63)
        let hundred = label + "." + String(repeating: "b", count: 31) + ".test"
        #expect(hundred.utf8.count == 100 && DomainSuffix.problem(hundred) == nil)
        let more = label + "." + String(repeating: "b", count: 32) + ".test"
        #expect(more.utf8.count == 101)
        #expect(DomainSuffix.problem(more) == "Use at most 4 parts and 100 characters.")
    }

    @Test func aLabelOf63BytesPassesAndTheShapeLimitsTheParts() {
        #expect(DomainSuffix.problem(String(repeating: "a", count: 63) + ".test") == nil)
        for ok in ["a.b.test", "a.b.internal", "a.home.arpa", "a.b.home.arpa", "xn--bcher-kva.test", "test"] {
            #expect(DomainSuffix.problem(ok) == nil, "\(ok)")
        }
        #expect(DomainSuffix.problem("a.b.c.home.arpa") != nil)
        #expect(DomainSuffix.problem("a.b.c.internal") == shape)
    }

    @Test func dotsAndWhitespaceAtTheEndsAreTrimmed() {
        #expect(DomainSuffix.problem("test.") == nil)
        #expect(DomainSuffix.problem(".test.") == nil)
        #expect(DomainSuffix.problem(" dev.test\n") == nil)
        #expect(DomainSuffix.valid(" dev.test\n") == "dev.test")
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
