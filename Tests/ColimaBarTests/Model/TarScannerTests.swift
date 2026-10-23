import Foundation
import Testing

@testable import ColimaBar

@Suite struct TarScannerTests {
    private func scan(_ data: Data, chunk: Int = 4096) throws -> TarScanner {
        var s = TarScanner()
        var i = 0
        while i < data.count {
            try s.feed(data[i..<min(i + chunk, data.count)])
            i += chunk
        }
        return s
    }

    private func failure(_ data: Data) -> TarScanner.Failure? {
        do {
            _ = try scan(data)
            return nil
        } catch { return error as? TarScanner.Failure }
    }

    @Test func aVolumeArchiveIsCompleteAtItsEndMarker() throws {
        let s = try scan(TarFixture.volume())
        #expect(s.isComplete && s.entryCount == 2 && s.sawContent)
    }

    @Test func anEmptyVolumeShowsOnlyTheRootFolder() throws {
        let s = try scan(TarFixture.directory("v/") + TarFixture.endMarker)
        #expect(s.isComplete && s.entryCount == 1 && !s.sawContent)
    }

    @Test func theEndMarkerCanSplitAcrossChunks() throws {
        let data = TarFixture.volume()
        var s = TarScanner()
        let cut = data.count - 700
        try s.feed(data[0..<cut])
        #expect(!s.isComplete)
        try s.feed(data[cut..<(cut + 100)])
        try s.feed(data[(cut + 100)...])
        #expect(s.isComplete)
    }

    @Test func oneByteChunksGiveTheSameResult() throws {
        let s = try scan(TarFixture.volume(files: [("v/a", String(repeating: "x", count: 700))]), chunk: 1)
        #expect(s.isComplete && s.entryCount == 2)
    }

    @Test func aMissingEndMarkerIsNotComplete() throws {
        let data = TarFixture.directory("v/") + TarFixture.entry("v/f", content: "hi")
        let s = try scan(data)
        #expect(!s.isComplete)
        #expect(throws: TarScanner.Failure.notComplete) { try s.finish() }
    }

    @Test func oneZeroBlockIsNotTheEnd() throws {
        let s = try scan(TarFixture.directory("v/") + Data(repeating: 0, count: 512))
        #expect(!s.isComplete)
    }

    @Test func anArchiveCutInsideFileDataIsNotComplete() throws {
        let data = TarFixture.entry("v/f", content: String(repeating: "x", count: 2000))
        let s = try scan(data[0..<1000])
        #expect(!s.isComplete)
    }

    @Test func aPaxPathReplacesTheName() throws {
        let tar = TarFixture.pax(["path": "v/long/name"]) + TarFixture.entry("short") + TarFixture.endMarker
        #expect(try scan(tar).isComplete)
    }

    @Test func aPaxPathOutsideTheVolumeIsUnsafe() {
        let tar = TarFixture.pax(["path": "../escape"]) + TarFixture.entry("v/ok") + TarFixture.endMarker
        #expect(failure(tar) == .unsafeEntry("../escape"))
    }

    @Test func aPaxSizeSkipsTheRightNumberOfBytes() throws {
        let content = String(repeating: "y", count: 1500)
        let header = TarHeader.block(name: "v/f", size: 0)
        let data = Data(content.utf8) + Data(repeating: 0, count: 512 * 3 - 1500)
        let tar = TarFixture.pax(["size": "1500"]) + header + data + TarFixture.endMarker
        #expect(try scan(tar).isComplete)
    }

    @Test func aPaxGlobalHeaderIsIgnored() throws {
        let global = TarFixture.pax(["path": "../bad"]).withFlag(0x67)
        #expect(try scan(global + TarFixture.entry("v/ok") + TarFixture.endMarker).isComplete)
    }

    @Test func aGnuLongNameReplacesTheName() throws {
        let long = "v/" + String(repeating: "d/", count: 80) + "file"
        let tar = TarFixture.gnuLong(long) + TarFixture.entry("truncated") + TarFixture.endMarker
        #expect(try scan(tar).isComplete)
    }

    @Test func aGnuLongNameOutsideTheVolumeIsUnsafe() {
        let tar = TarFixture.gnuLong("/etc/passwd") + TarFixture.entry("x") + TarFixture.endMarker
        #expect(failure(tar) == .unsafeEntry("/etc/passwd"))
    }

    @Test(arguments: ["../x", "v/../../x", "/abs", "etc/passwd", "vv/x", "x/v/y", "", "v/a/../../b"])
    func anUnsafeNameIsRefused(name: String) {
        #expect(failure(TarFixture.entry(name) + TarFixture.endMarker) != nil)
    }

    @Test(arguments: ["v", "v/", "v/f", "v/a/b/c", "v/.hidden", "v/a..b", "v/./x"])
    func aSafeNameIsAccepted(name: String) throws {
        #expect(try scan(TarFixture.entry(name) + TarFixture.endMarker).isComplete)
    }

    @Test func aHardLinkInsideTheVolumeIsAccepted() throws {
        let tar = TarFixture.entry("v/a", content: "x") + TarFixture.entry("v/b", flag: 0x31, linkName: "v/a")
        #expect(try scan(tar + TarFixture.endMarker).isComplete)
    }

    @Test(arguments: ["/etc/passwd", "../x", "other/file"])
    func aHardLinkOutsideTheVolumeIsRefused(target: String) {
        let tar = TarFixture.entry("v/b", flag: 0x31, linkName: target) + TarFixture.endMarker
        #expect(failure(tar) == .unsafeEntry("v/b"))
    }

    @Test func aSymlinkMayPointAnywhere() throws {
        let tar = TarFixture.entry("v/l", flag: 0x32, linkName: "/etc/passwd") + TarFixture.endMarker
        #expect(try scan(tar).isComplete)
    }

    @Test(arguments: [UInt8(0x33), UInt8(0x34)])
    func aDeviceIsRefused(flag: UInt8) {
        #expect(failure(TarFixture.entry("v/dev", flag: flag) + TarFixture.endMarker) == .unsafeEntry("v/dev"))
    }

    @Test func aFifoIsAccepted() throws {
        #expect(try scan(TarFixture.entry("v/pipe", flag: 0x36) + TarFixture.endMarker).isComplete)
    }

    @Test func aBadChecksumIsRefused() {
        var tar = TarFixture.entry("v/f", content: "x") + TarFixture.endMarker
        tar[10] ^= 0xFF
        #expect(failure(tar) == .badHeader)
    }

    @Test func textThatIsNotTarIsRefused() {
        #expect(failure(Data(String(repeating: "hello world\n", count: 100).utf8)) == .badHeader)
    }

    @Test func aHugePaxRecordIsRefused() {
        let header = TarHeader.block(name: "p", size: Int64(TarScanner.maxRecord + 1), flag: 0x78)
        #expect(failure(header) == .badHeader)
    }

    @Test func bytesAfterTheEndMarkerAreIgnored() throws {
        let s = try scan(TarFixture.volume() + Data(repeating: 0, count: 8192) + Data("junk".utf8))
        #expect(s.isComplete)
    }

    @Test func skippableCountsTheDataThatAFileReaderCanSeekOver() throws {
        var s = TarScanner()
        try s.feed(TarHeader.block(name: "v/f", size: 1000))
        #expect(s.skippable == 1024)
        s.skip(1024)
        #expect(s.skippable == 0 && s.wantsBytes == 512)
    }

    @Test(arguments: ["/etc/passwd", "../x", "other/file"])
    func aHardLinkOutsideTheVolumeInAPaxRecordIsRefused(target: String) {
        let tar =
            TarFixture.pax(["linkpath": target]) + TarFixture.entry("v/b", flag: 0x31, linkName: "v/ok")
            + TarFixture.endMarker
        #expect(failure(tar) == .unsafeEntry("v/b"))
    }

    @Test func aHardLinkInsideTheVolumeInAPaxRecordIsAccepted() throws {
        let tar =
            TarFixture.entry("v/a", content: "x") + TarFixture.pax(["linkpath": "v/a"])
            + TarFixture.entry("v/b", flag: 0x31, linkName: "") + TarFixture.endMarker
        #expect(try scan(tar).isComplete)
    }

    @Test(arguments: ["/etc/passwd", "../x", "other/file"])
    func aHardLinkOutsideTheVolumeInAGnuLongLinkIsRefused(target: String) {
        let tar =
            TarFixture.gnuLong(target, flag: 0x4B) + TarFixture.entry("v/b", flag: 0x31, linkName: "v/ok")
            + TarFixture.endMarker
        #expect(failure(tar) == .unsafeEntry("v/b"))
    }

    @Test func aHardLinkInsideTheVolumeInAGnuLongLinkIsAccepted() throws {
        let tar =
            TarFixture.entry("v/a", content: "x") + TarFixture.gnuLong("v/a", flag: 0x4B)
            + TarFixture.entry("v/b", flag: 0x31, linkName: "") + TarFixture.endMarker
        #expect(try scan(tar).isComplete)
    }

    @Test func aLongLinkOnlyAppliesToTheNextEntry() throws {
        // The long link `../x` belongs to the symlink. The hard link after it has its own target.
        let tar =
            TarFixture.entry("v/a", content: "x") + TarFixture.gnuLong("../x", flag: 0x4B)
            + TarFixture.entry("v/l", flag: 0x32, linkName: "") + TarFixture.entry("v/b", flag: 0x31, linkName: "v/a")
            + TarFixture.endMarker
        #expect(try scan(tar).isComplete)
    }

    // MARK: Names of an image archive

    private func scanImages(_ data: Data) throws -> TarScanner {
        var s = TarScanner(names: .any)
        try s.feed(data)
        return s
    }

    @Test func anImageArchiveHasAnyRelativeName() throws {
        let tar =
            TarFixture.entry("blobs/", flag: 0x35) + TarFixture.entry("blobs/sha256/abc", content: "x")
            + TarFixture.entry("manifest.json", content: "[]") + TarFixture.entry("oci-layout", content: "{}")
            + TarFixture.endMarker
        let s = try scanImages(tar)
        #expect(s.isComplete && s.sawContent && s.entryCount == 4)
    }

    @Test func anImageArchiveRefusesAbsoluteNamesAndDotDot() {
        for name in ["/etc/x", "a/../b", "../x"] {
            #expect(throws: TarScanner.Failure.unsafeEntry(name)) {
                _ = try scanImages(TarFixture.entry(name, content: "x") + TarFixture.endMarker)
            }
        }
    }

    @Test func aVolumeArchiveStillWantsTheRootFolder() {
        #expect(throws: TarScanner.Failure.unsafeEntry("manifest.json")) {
            var s = TarScanner()
            try s.feed(TarFixture.entry("manifest.json") + TarFixture.endMarker)
        }
    }

    @Test func anImageArchiveRefusesADeviceAndAnOutsideHardLink() {
        #expect(throws: TarScanner.Failure.unsafeEntry("dev")) {
            _ = try scanImages(TarFixture.entry("dev", flag: 0x33) + TarFixture.endMarker)
        }
        #expect(throws: TarScanner.Failure.unsafeEntry("link")) {
            _ = try scanImages(TarFixture.entry("link", flag: 0x31, linkName: "/etc/passwd") + TarFixture.endMarker)
        }
    }
}

extension Data {
    /// The same block with another type flag, and a fresh checksum.
    fileprivate func withFlag(_ flag: UInt8) -> Data {
        var bytes = Array(self.prefix(512))
        bytes[156] = flag
        for i in 148..<156 { bytes[i] = 0x20 }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        let digits = Array(String(sum, radix: 8).utf8)
        let field = [UInt8](repeating: 0x30, count: 6 - digits.count) + digits + [0, 0x20]
        for (i, byte) in field.enumerated() { bytes[148 + i] = byte }
        return Data(bytes) + self.dropFirst(512)
    }
}
