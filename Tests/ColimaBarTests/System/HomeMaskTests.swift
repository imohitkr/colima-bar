import Testing

@testable import ColimaBar

@Suite struct HomeMaskTests {
    @Test func theHomeFolderAndItsPathsBecomeATilde() {
        #expect(HomeMask.apply("/Users/me/.zshrc and /Users/me", home: "/Users/me") == "~/.zshrc and ~")
        #expect(HomeMask.apply("(\"/Users/me\"): /Users/me, ok", home: "/Users/me") == "(\"~\"): ~, ok")
    }

    @Test func aFolderWithALongerNameStaysAsItIs() {
        #expect(
            HomeMask.apply("/Users/meg/x /Users/me.old /Users/me-b", home: "/Users/me")
                == "/Users/meg/x /Users/me.old /Users/me-b")
        #expect(HomeMask.apply("/Users/meg and /Users/me/x", home: "/Users/me") == "/Users/meg and ~/x")
    }

    @Test func noHomeMeansNoChange() {
        #expect(HomeMask.apply("/a/b", home: "") == "/a/b")
        #expect(HomeMask.apply("/a/b", home: "/") == "/a/b")
    }
}
