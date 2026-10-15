import Foundation
import Testing

@testable import ColimaBar

@Suite struct SymlinkWriteTests {
    @Test func followsARelativeAndAnAbsoluteLink() throws {
        let dir = try TempFolder()
        let real = dir.path + "/real.txt"
        try "old".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/rel", withDestinationPath: "real.txt")
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/abs", withDestinationPath: real)
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/chain", withDestinationPath: "rel")
        #expect(SymlinkWrite.target(of: dir.path + "/rel") == real)
        #expect(SymlinkWrite.target(of: dir.path + "/abs") == real)
        #expect(SymlinkWrite.target(of: dir.path + "/chain") == real)
        #expect(SymlinkWrite.target(of: real) == real)
    }

    @Test func writeKeepsTheLinkAndTheModeOfTheFile() throws {
        let dir = try TempFolder()
        let real = dir.path + "/real.txt"
        let link = dir.path + "/link.txt"
        try "old".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let target = try SymlinkWrite.write(Data("new".utf8), to: link)
        #expect(target == real)
        #expect(try String(contentsOfFile: real, encoding: .utf8) == "new")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == real)
        #expect(try FileManager.default.attributesOfItem(atPath: real)[.posixPermissions] as? Int == 0o600)
    }
}
