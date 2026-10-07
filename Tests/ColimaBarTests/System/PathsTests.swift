import Foundation
import Testing

@testable import ColimaBar

@Suite struct PathsTests {
    @Test func kubeContextNames() {
        #expect(Paths.kubeContext("default") == "colima")
        #expect(Paths.kubeContext("work") == "colima-work")
        #expect(Paths.socket("work").hasSuffix("/.config/colima/work/docker.sock"))
        #expect(Paths.profilesDir == Paths.cacheDir + "/profiles")
        #expect(Paths.profileSocket("work") == Paths.profilesDir + "/work.sock")
    }
}
