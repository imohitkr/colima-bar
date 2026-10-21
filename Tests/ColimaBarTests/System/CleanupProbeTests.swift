import Foundation
import Testing

@testable import ColimaBar

@Suite struct CleanupProbeTests {
    private func make(_ folder: TempFolder, _ relative: String) throws -> String {
        let path = folder.path + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return path
    }

    /// A sparse file of `apparent` bytes with `written` bytes of data.
    private func sparse(_ path: String, apparent: Int64, written: Int) throws {
        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(ftruncate(fd, off_t(apparent)) == 0)
        let data = [UInt8](repeating: 1, count: written)
        try #require(pwrite(fd, data, written, 0) == written)
    }

    @Test func measuresTheAllocatedSizeOfASparseFile() async throws {
        let folder = try TempFolder()
        try sparse(try make(folder, "colima/disk"), apparent: 1 << 30, written: 1 << 20)
        let size = try #require(await CleanupProbe.diskImage(profile: "default", limaDir: folder.path))
        #expect(size.apparent == 1 << 30)
        #expect(size.allocated >= 1 << 20 && size.allocated <= 2 << 20)
    }

    @Test func skipsASymlinkAndAMissingFile() async throws {
        let folder = try TempFolder()
        let target = try make(folder, "elsewhere/real")
        try sparse(target, apparent: 4096, written: 4096)
        let link = try make(folder, "colima/disk")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(await CleanupProbe.diskImage(profile: "default", limaDir: folder.path) == nil)
        #expect(CleanupProbe.stat(folder.path + "/colima/diffdisk") == nil)
        #expect(CleanupProbe.stat(folder.path + "/colima") == nil)  // a folder is not a regular file
    }

    @Test func sumsTheRootAndTheDataDisk() async throws {
        let folder = try TempFolder()
        try sparse(try make(folder, "colima-work/disk"), apparent: 1 << 20, written: 4096)
        try sparse(try make(folder, "_disks/colima-work/datadisk"), apparent: 2 << 20, written: 4096)
        let size = try #require(await CleanupProbe.diskImage(profile: "work", limaDir: folder.path))
        #expect(size.apparent == 3 << 20)
        #expect(size.allocated >= 8192)
    }
}
