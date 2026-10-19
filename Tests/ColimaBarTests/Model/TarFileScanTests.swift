import Foundation
import Testing

@testable import ColimaBar

@Suite struct TarFileScanTests {
    private func scan(_ data: Data) throws -> TarFileScan.Summary {
        let folder = try TempFolder()
        let path = folder.path + "/b.tar"
        try data.write(to: URL(fileURLWithPath: path))
        return try TarFileScan.scan(path: path)
    }

    private func failure(_ data: Data) -> TarFileScan.Failure? {
        do {
            _ = try scan(data)
            return nil
        } catch { return error as? TarFileScan.Failure }
    }

    @Test func aBackupFileGivesItsFactsAndTheSkipOffset() throws {
        let meta = VolumeBackupMeta(name: "pgdata", labels: ["a": "b"])
        let file = meta.entry() + TarFixture.volume()
        let s = try scan(file)
        #expect(s.meta == meta && s.skip == 1024 && s.size == Int64(file.count) && s.entryCount == 2)
    }

    @Test func anArchiveWithoutTheEntryIsAccepted() throws {
        let s = try scan(TarFixture.volume())
        #expect(s.meta == nil && s.skip == 0)
    }

    @Test func aLargeFileIsScannedBySeekingOverItsData() throws {
        let big = String(repeating: "z", count: 3 << 20)
        let s = try scan(TarFixture.volume(files: [("v/big", big), ("v/small", "x")]))
        #expect(s.entryCount == 3)
    }

    @Test func aCutFileIsNotComplete() {
        let data = TarFixture.volume(files: [("v/f", String(repeating: "x", count: 5000))])
        #expect(failure(data.prefix(2000)) == .notComplete)
    }

    @Test func aCutFileWithAnOversizeEntryIsNotComplete() {
        let data = TarFixture.directory("v/") + TarHeader.block(name: "v/f", size: 1 << 30)
        #expect(failure(data) == .notComplete)
    }

    @Test func anUnsafeEntryNamesItsPath() {
        let data = TarFixture.directory("v/") + TarFixture.entry("v/../../etc/x") + TarFixture.endMarker
        #expect(failure(data) == .unsafeEntry("v/../../etc/x"))
    }

    @Test func aGzipFileIsReportedAsCompressed() {
        #expect(failure(Data([0x1F, 0x8B, 0x08, 0x00]) + Data(repeating: 0, count: 600)) == .compressed)
    }

    @Test func anEmptyFileIsNotComplete() {
        #expect(failure(Data()) == .notComplete)
    }

    @Test func aMissingFileIsUnreadable() {
        #expect(throws: TarFileScan.Failure.unreadable) { try TarFileScan.scan(path: "/nonexistent/cb-none.tar") }
    }

    @Test func aFolderIsUnreadable() throws {
        let folder = try TempFolder()
        #expect(throws: TarFileScan.Failure.unreadable) { try TarFileScan.scan(path: folder.path) }
    }
}
