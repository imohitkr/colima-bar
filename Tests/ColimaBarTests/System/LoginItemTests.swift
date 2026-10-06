import Foundation
import Testing

@testable import ColimaBar

@Suite struct LoginItemTests {
    @Test func plistRoundTripIsNotOutdated() throws {
        let exe = "/Applications/ColimaBar.app/Contents/MacOS/ColimaBar"
        let data = try PropertyListSerialization.data(
            fromPropertyList: LoginItem.plistContents(exe: exe),
            format: .xml, options: 0)
        let read = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(!LoginItem.plistIsOutdated(read, exe: exe))
        let limits = read["SoftResourceLimits"] as? [String: Any]
        #expect(limits?["NumberOfFiles"] as? Int == 8192)

        // A plist from an older version (no SoftResourceLimits) is outdated.
        var old = read
        old["SoftResourceLimits"] = nil
        #expect(LoginItem.plistIsOutdated(old, exe: exe))
    }

    @Test func installedPaths() {
        #expect(LoginItem.isInstalled("/Applications/ColimaBar.app"))
        #expect(LoginItem.isInstalled("\(Paths.home)/Applications/ColimaBar.app"))
        #expect(!LoginItem.isInstalled("/Volumes/ColimaBar/ColimaBar.app"))
        #expect(!LoginItem.isInstalled("/private/var/folders/x/AppTranslocation/Y/d/ColimaBar.app"))
    }
}
