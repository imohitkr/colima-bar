import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct PrivateFileWriterTests {
    private func mode(_ path: String) -> mode_t {
        var st = stat()
        lstat(path, &st)
        return st.st_mode & 0o777
    }

    private func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    @Test func aCommittedFileHasMode0600AndAllBytes() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        let w = try PrivateFileWriter(destination: path, replace: true)
        try w.write(Data("abc".utf8))
        try w.write(Data("def".utf8))
        try w.commit()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "abcdef")
        #expect(mode(path) == 0o600 && w.bytes == 6)
    }

    @Test func theFileAppearsOnlyAtCommit() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        let w = try PrivateFileWriter(destination: path, replace: true)
        try w.write(Data("abc".utf8))
        #expect(!exists(path))
        try w.commit()
        #expect(exists(path))
    }

    @Test func theTemporaryFileIsPrivateFromTheFirstByte() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        let w = try PrivateFileWriter(destination: path, replace: true)
        #expect(mode("\(path).\(getpid()).tmp") == 0o600)
        w.abort()
    }

    @Test func anAbortLeavesNoFile() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        let w = try PrivateFileWriter(destination: path, replace: true)
        try w.write(Data("abc".utf8))
        w.abort()
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
    }

    @Test func aWriterThatGoesAwayWithoutACommitLeavesNoFile() throws {
        let dir = try TempFolder()
        do {
            let w = try PrivateFileWriter(destination: dir.path + "/b.tar", replace: true)
            try w.write(Data("abc".utf8))
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
    }

    @Test func aReplaceOverwritesAnOldFile() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        try "old".write(toFile: path, atomically: true, encoding: .utf8)
        let w = try PrivateFileWriter(destination: path, replace: true)
        try w.write(Data("new".utf8))
        try w.commit()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new")
    }

    @Test func aStaleTemporaryFileDoesNotStopTheWriter() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        try "stale".write(toFile: "\(path).\(getpid()).tmp", atomically: true, encoding: .utf8)
        let w = try PrivateFileWriter(destination: path, replace: true)
        try w.write(Data("x".utf8))
        try w.commit()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "x")
    }

    @Test func aReplaceOfASymlinkReplacesTheLinkAndNeverFollowsIt() throws {
        let dir = try TempFolder()
        let target = dir.path + "/target.txt"
        try "keep".write(toFile: target, atomically: true, encoding: .utf8)
        let path = dir.path + "/b.tar"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        let w = try PrivateFileWriter(destination: path, replace: true)
        try w.write(Data("new".utf8))
        try w.commit()
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new")
    }

    @Test func aTemporaryLinkIsNotFollowed() throws {
        let dir = try TempFolder()
        let target = dir.path + "/target.txt"
        try "keep".write(toFile: target, atomically: true, encoding: .utf8)
        let path = dir.path + "/b.tar"
        try FileManager.default.createSymbolicLink(atPath: "\(path).\(getpid()).tmp", withDestinationPath: target)
        let w = try PrivateFileWriter(destination: path, replace: true)
        try w.write(Data("new".utf8))
        try w.commit()
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
    }

    @Test func withoutReplaceAnExistingFileIsRefused() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        try "old".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: POSIXError.self) { _ = try PrivateFileWriter(destination: path, replace: false) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "old")
    }

    @Test func withoutReplaceASymlinkIsRefused() throws {
        let dir = try TempFolder()
        let target = dir.path + "/target.txt"
        let path = dir.path + "/b.tar"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        #expect(throws: POSIXError.self) { _ = try PrivateFileWriter(destination: path, replace: false) }
        #expect(!exists(target))
    }

    @Test func withoutReplaceAnAbortRemovesTheFile() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        let w = try PrivateFileWriter(destination: path, replace: false)
        try w.write(Data("abc".utf8))
        #expect(mode("\(path).\(getpid()).tmp") == 0o600)
        w.abort()
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
    }

    @Test func withoutReplaceTheFileAppearsOnlyAtCommit() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        let w = try PrivateFileWriter(destination: path, replace: false)
        try w.write(Data("abc".utf8))
        #expect(!exists(path))
        try w.commit()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "abc")
        #expect(mode(path) == 0o600)
    }

    @Test func withoutReplaceAFileThatAppearsDuringTheWriteIsNeverReplaced() throws {
        let dir = try TempFolder()
        let path = dir.path + "/b.tar"
        let w = try PrivateFileWriter(destination: path, replace: false)
        try w.write(Data("new".utf8))
        try "other".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: POSIXError.self) { try w.commit() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "other")
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["b.tar"])
    }

    @Test func aWriteAfterAnAbortFails() throws {
        let dir = try TempFolder()
        let w = try PrivateFileWriter(destination: dir.path + "/b.tar", replace: true)
        w.abort()
        #expect(throws: POSIXError.self) { try w.write(Data("x".utf8)) }
    }
}
