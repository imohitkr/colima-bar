import Foundation
import Testing

@testable import ColimaBar

@Suite struct PathsTests {
    @Test func kubeContextNames() {
        #expect(Paths.kubeContext("default") == "colima")
        #expect(Paths.kubeContext("work") == "colima-work")
        #expect(Paths.socket("work") == Paths.colimaDir + "/work/docker.sock")
        #expect(Paths.profilesDir == Paths.cacheDir + "/profiles")
        #expect(Paths.profileSocket("work") == Paths.profilesDir + "/work.sock")
    }

    @Test func colimaDirFollowsTheRulesOfColima() {
        let home = "/Users/me"
        func dir(_ env: [String: String], _ existing: Set<String>) -> String {
            Paths.colimaDir(env: env, home: home, exists: { existing.contains($0) })
        }
        let custom = ["COLIMA_HOME": "/data/colima"]
        // COLIMA_HOME wins when its path exists, also over ~/.colima.
        #expect(dir(custom, ["/data/colima", "/Users/me/.colima"]) == "/data/colima")
        // A missing or empty COLIMA_HOME is ignored.
        #expect(dir(custom, ["/Users/me/.colima"]) == "/Users/me/.colima")
        #expect(dir(["COLIMA_HOME": ""], [""]) == "/Users/me/.config/colima")
        // Else ~/.colima if it exists, else the pinned XDG_CONFIG_HOME folder.
        #expect(dir([:], ["/Users/me/.colima"]) == "/Users/me/.colima")
        #expect(dir([:], []) == "/Users/me/.config/colima")
    }

    @Test func limaDirIsLimaHomeOrTheLimaFolderOfColima() {
        #expect(Paths.limaDir(env: ["LIMA_HOME": "/data/lima"], colimaDir: "/c") == "/data/lima")
        #expect(Paths.limaDir(env: ["LIMA_HOME": ""], colimaDir: "/c") == "/c/_lima")
        #expect(Paths.limaDir(env: [:], colimaDir: "/c") == "/c/_lima")
    }
}
