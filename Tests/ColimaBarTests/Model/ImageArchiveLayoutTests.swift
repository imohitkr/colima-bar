import Foundation
import Testing

@testable import ColimaBar

@Suite struct ImageArchiveLayoutTests {
    private func detect(_ tar: Data) throws -> ImageArchiveLayout {
        let folder = try TempFolder()
        let path = folder.path + "/a.tar"
        try tar.write(to: URL(fileURLWithPath: path))
        return ImageArchiveLayout.detect(path: path)
    }

    private let blob = TarFixture.entry("blobs/sha256/abc", content: String(repeating: "x", count: 1300))

    @Test func aDockerArchiveHasAManifest() throws {
        let tar = blob + TarFixture.entry("manifest.json", content: "[]") + TarFixture.endMarker
        #expect(try detect(tar) == .docker)
    }

    @Test func anArchiveWithBothNamesCountsAsDocker() throws {
        let tar =
            TarFixture.entry("index.json", content: "{}") + blob + TarFixture.entry("manifest.json", content: "[]")
            + TarFixture.endMarker
        #expect(try detect(tar) == .docker)
    }

    @Test func anOCILayoutHasOnlyAnIndex() throws {
        let tar =
            TarFixture.entry("oci-layout", content: "{}") + blob + TarFixture.entry("index.json", content: "{}")
            + TarFixture.endMarker
        #expect(try detect(tar) == .oci)
    }

    @Test func anUnreadableOrEmptyFileCountsAsDocker() throws {
        #expect(try detect(Data()) == .docker)
        #expect(ImageArchiveLayout.detect(path: "/nonexistent/a.tar") == .docker)
    }
}
