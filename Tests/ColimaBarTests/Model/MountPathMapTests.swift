import Foundation
import Testing

@testable import ColimaBar

@Suite struct MountPathMapTests {
    private let home = "/Users/ab"

    private func map(_ vm: String, _ mounts: [VMMount], defaultHome: Bool = false) -> String? {
        MountPathMap.macPath(vmPath: vm, mounts: mounts, defaultHome: defaultHome, home: home)
    }

    @Test func aMountShowsTheSamePathInTheVM() {
        #expect(map("/Users/ab/code/app", [VMMount(location: "/Users/ab/code")]) == "/Users/ab/code/app")
    }

    @Test func theDefaultHomeFolderIsMounted() {
        #expect(map("/Users/ab/docs", [], defaultHome: true) == "/Users/ab/docs")
        #expect(map("/Users/ab/docs", [], defaultHome: false) == nil)
    }

    @Test func aMountPointMovesThePathInTheVM() {
        let mount = VMMount(location: "/Users/ab/data", mountPoint: "/mnt/data")
        #expect(map("/mnt/data/x", [mount]) == "/Users/ab/data/x")
        #expect(map("/Users/ab/data/x", [mount]) == nil)
    }

    @Test func aFolderThatOnlyStartsWithTheNameIsNotInsideIt() {
        #expect(map("/Users/abc/x", [VMMount(location: "/Users/ab")]) == nil)
        #expect(map("/Users/abc", [], defaultHome: true) == nil)
    }

    @Test func aTildeMeansTheHomeFolder() {
        #expect(map("/Users/ab/code/x", [VMMount(location: "~/code")]) == "/Users/ab/code/x")
        #expect(map("/Users/ab/x", [VMMount(location: "~")]) == "/Users/ab/x")
    }

    @Test func noMountGivesNoPath() {
        #expect(map("/var/lib/data", [VMMount(location: "/Users/ab")]) == nil)
        #expect(map("/x", []) == nil)
    }

    @Test func aTrailingSlashChangesNothing() {
        #expect(map("/Users/ab/code/", [VMMount(location: "/Users/ab/code/")]) == "/Users/ab/code")
    }

    @Test func aPathWithDotDotHasNoMatch() {
        #expect(map("/Users/ab/code/../../etc", [VMMount(location: "/Users/ab")]) == nil)
        #expect(map("/Users/ab/code", [VMMount(location: "/Users/ab/../x")]) == nil)
    }

    @Test func aRelativePathHasNoMatch() {
        #expect(map("code/app", [VMMount(location: "/Users/ab")]) == nil)
    }

    @Test func theDeepestMountWins() {
        let mounts = [
            VMMount(location: "/Users/ab"),
            VMMount(location: "/Volumes/disk/code", mountPoint: "/Users/ab/code"),
        ]
        #expect(map("/Users/ab/code/x", mounts) == "/Volumes/disk/code/x")
    }
}
