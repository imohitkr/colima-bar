import Foundation
import Testing

@testable import ColimaBar

@Suite struct VolumeBackupMetaTests {
    private func head(of data: Data) throws -> VolumeBackupMeta.Head? {
        let folder = try TempFolder()
        let path = folder.path + "/m.tar"
        try data.write(to: URL(fileURLWithPath: path))
        let fd = open(path, O_RDONLY)
        defer { close(fd) }
        return VolumeBackupMeta.readHead(fd: fd)
    }

    @Test func theEntryIsAValidTarEntryThatReadsBack() throws {
        let meta = VolumeBackupMeta(
            name: "pgdata", driver: "local", labels: ["a": "b"], created: "2026-01-01T00:00:00Z", app: "ColimaBar 1")
        let entry = meta.entry()
        #expect(entry.count % 512 == 0)
        let h = try head(of: entry + TarFixture.volume())
        #expect(h?.meta == meta && h?.skip == Int64(entry.count))
    }

    @Test func theScannerAcceptsTheEntryThenTheDockerStream() throws {
        // The restore skips the entry by its size, so the scan starts at the Docker archive.
        let meta = VolumeBackupMeta(name: "v1")
        var s = TarScanner()
        try s.feed(TarFixture.volume())
        #expect(s.isComplete)
        #expect(meta.entry().count == 1024)
    }

    @Test func aFileWithoutTheEntryHasNothingToSkip() throws {
        let h = try head(of: TarFixture.volume())
        #expect(h == VolumeBackupMeta.Head(meta: nil, skip: 0))
    }

    @Test func anEntryOfMoreThanSixtyFourKilobytesIsNotRead() throws {
        let big = TarHeader.block(name: VolumeBackupMeta.entryName, size: Int64(VolumeBackupMeta.maxData + 1))
        #expect(try head(of: big + Data(repeating: 0x20, count: 70_000)) == nil)
    }

    @Test func badJSONGivesNoFactsButTheEntryIsStillSkipped() throws {
        let entry = TarFixture.entry(VolumeBackupMeta.entryName, content: "not json")
        let h = try head(of: entry + TarFixture.volume())
        #expect(h?.meta == nil && h?.skip == 1024)
    }

    @Test func manyLabelsAreLeftOutToKeepTheEntrySmall() {
        var labels: [String: String] = [:]
        for i in 0..<2000 { labels["key\(i)"] = String(repeating: "v", count: 60) }
        let entry = VolumeBackupMeta(name: "big", labels: labels).entry()
        #expect(entry.count <= 512 + VolumeBackupMeta.maxData + 512)
    }

    @Test func theSameNameKeepsTheLabels() {
        let meta = VolumeBackupMeta(name: "web", labels: ["com.docker.compose.project": "shop"])
        #expect(meta.labels(forTarget: "web") == ["com.docker.compose.project": "shop"])
    }

    @Test func anotherNameGetsNoLabels() {
        let meta = VolumeBackupMeta(name: "web", labels: ["com.docker.compose.project": "shop"])
        #expect(meta.labels(forTarget: "web-copy").isEmpty)
    }

    @Test func tooManyLabelsAreNotRestored() {
        var labels: [String: String] = [:]
        for i in 0...VolumeBackupMeta.maxLabels { labels["k\(i)"] = "v" }
        #expect(VolumeBackupMeta(name: "web", labels: labels).labels(forTarget: "web").isEmpty)
    }
}
