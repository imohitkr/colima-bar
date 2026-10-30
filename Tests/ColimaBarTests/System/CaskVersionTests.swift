import Testing

@testable import ColimaBar

@Suite struct CaskVersionTests {
    @Test func readsTheVersionLineOfTheCask() {
        let cask = """
            cask "colima-bar" do
              version "0.18.0"
              sha256 "b61c8d4e5b2e266923a601008b10e907abc28229ccd2197394fc97afa2337ac3"

              url "https://github.com/imohitkr/colima-bar/releases/download/v#{version}/ColimaBar.zip"
            end
            """
        #expect(CaskVersion.parse(cask) == "0.18.0")
    }

    @Test(arguments: [
        "", "cask \"colima-bar\" do\nend", "  version \"\"", "  version \"latest\"", "  version \"v0.18.0\"",
        "  version \"0.18\"", "  version \"0.18.0-beta\"", "  version \"0.18.0\"\n  version \"0.19.0\"",
        "  version 0.18.0",
    ])
    func givesNilForACaskWithoutOneValidVersion(text: String) {
        #expect(CaskVersion.parse(text) == nil)
    }

    @Test func theURLIsTheCaskOnTheMainBranchOfTheTap() {
        #expect(
            CaskVersion.url.absoluteString
                == "https://raw.githubusercontent.com/imohitkr/homebrew-tap/main/Casks/colima-bar.rb")
    }
}
