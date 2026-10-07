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

    @Test func colimaDirUsesTheFirstRuleThatApplies() {
        let home = "/Users/me"
        let dotColima = "/Users/me/.colima"
        let dotConfig = "/Users/me/.config/colima"
        func dir(_ env: [String: String], _ existing: Set<String>) -> String {
            Paths.colimaDir(env: env, home: home, exists: { existing.contains($0) })
        }
        let custom = ["COLIMA_HOME": "/data/colima"]
        let xdg = ["XDG_CONFIG_HOME": "/xdg"]
        // 1. COLIMA_HOME wins when its path exists, also over ~/.colima.
        #expect(dir(custom, ["/data/colima", dotColima, dotConfig]) == "/data/colima")
        // A missing or empty COLIMA_HOME is ignored.
        #expect(dir(custom, [dotColima]) == dotColima)
        #expect(dir(["COLIMA_HOME": ""], [""]) == dotColima)
        // 2. ~/.colima if it exists, also over ~/.config/colima and XDG_CONFIG_HOME.
        #expect(dir(xdg, [dotColima, dotConfig]) == dotColima)
        // 3. ~/.config/colima if it exists, also when XDG_CONFIG_HOME points elsewhere.
        #expect(dir([:], [dotConfig]) == dotConfig)
        #expect(dir(xdg, [dotConfig]) == dotConfig)
        // 4. $XDG_CONFIG_HOME/colima when no folder exists.
        #expect(dir(xdg, []) == "/xdg/colima")
        #expect(dir(["XDG_CONFIG_HOME": ""], []) == dotColima)
        // 5. Else ~/.colima, the default of Colima on macOS.
        #expect(dir([:], []) == dotColima)
    }

    @Test func colimaFoldersFollowTheColimaFolder() {
        let folders = Paths.colimaFolders(env: [:], home: "/Users/me", exists: { $0 == "/Users/me/.config/colima" })
        #expect(
            folders == Paths.ColimaFolders(colima: "/Users/me/.config/colima", lima: "/Users/me/.config/colima/_lima"))
        let moved = Paths.colimaFolders(
            env: ["LIMA_HOME": "/data/lima"], home: "/Users/me", exists: { $0 == "/Users/me/.colima" })
        #expect(moved == Paths.ColimaFolders(colima: "/Users/me/.colima", lima: "/data/lima"))
    }

    @Test func limaDirIsLimaHomeOrTheLimaFolderOfColima() {
        #expect(Paths.limaDir(env: ["LIMA_HOME": "/data/lima"], colimaDir: "/c") == "/data/lima")
        #expect(Paths.limaDir(env: ["LIMA_HOME": ""], colimaDir: "/c") == "/c/_lima")
        #expect(Paths.limaDir(env: [:], colimaDir: "/c") == "/c/_lima")
    }
}
