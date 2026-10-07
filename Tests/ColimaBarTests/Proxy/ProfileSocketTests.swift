import Foundation
import Testing

@testable import ColimaBar

@Suite struct ProfileSocketTests {
    @Test func thePathIsTheProfileNameInTheFolder() {
        #expect(ProfileSocket.path(dir: "/tmp/p", profile: "work") == "/tmp/p/work.sock")
        #expect(Paths.profileSocket("work")?.hasSuffix("/.cache/colima-bar/profiles/work.sock") == true)
    }

    @Test func pathsAndTheirTemporaryNameFitInSunPath() {
        // sun_path is 104 bytes with the NUL; listen() binds at PATH.tmp first.
        #expect(ProfileSocket.maxPathBytes == 99)
        let dir = "/tmp/p"
        let room = ProfileSocket.maxPathBytes - "\(dir)/".utf8.count - ".sock".utf8.count
        let longest = String(repeating: "a", count: room)
        let path = ProfileSocket.path(dir: dir, profile: longest)
        #expect(path?.utf8.count == ProfileSocket.maxPathBytes)
        #expect(ProfileSocket.path(dir: dir, profile: longest + "a") == nil)
    }

    @Test func aLongProfileNameBindsAtItsLongestPath() throws {
        // The longest accepted path really binds, with its .tmp name.
        let dir = TestSocketPath.uniqueDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let room = ProfileSocket.maxPathBytes - "\(dir)/".utf8.count - ".sock".utf8.count
        let path = try #require(ProfileSocket.path(dir: dir, profile: String(repeating: "b", count: room)))
        let fd = try UnixSocket.listen(path)
        close(fd)
        unlink(path)
    }

    @Test func invalidNamesGetNoPath() {
        for name in ["", "..", ".x", "a/b", "a b"] { #expect(ProfileSocket.path(dir: "/tmp/p", profile: name) == nil) }
    }

    @Test func fileNamesMapBackToProfiles() {
        #expect(ProfileSocket.profile(fileName: "work.sock") == "work")
        #expect(ProfileSocket.profile(fileName: "work.sock.tmp") == nil)
        #expect(ProfileSocket.profile(fileName: ".sock") == nil)
        #expect(ProfileSocket.profile(fileName: "notes.txt") == nil)
    }
}
