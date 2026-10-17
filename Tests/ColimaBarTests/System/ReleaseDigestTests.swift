import Foundation
import Testing

@testable import ColimaBar

@Suite struct ReleaseDigestTests {
    private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test func hashesKnownVectors() {
        #expect(ReleaseDigest().hex() == emptyDigest)
        var d = ReleaseDigest()
        d.update(Data("abc".utf8))
        #expect(d.hex() == abcDigest)
        #expect(d.count == 3)
    }

    @Test func chunkBoundariesDoNotChangeTheResult() {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        var whole = ReleaseDigest()
        whole.update(data)
        for size in [1, 7, 64, 65, 4096, 9_999] {
            var parts = ReleaseDigest()
            var i = 0
            while i < data.count {
                parts.update(data.subdata(in: i..<min(i + size, data.count)))
                i += size
            }
            #expect(parts.hex() == whole.hex(), "chunk size \(size)")
            #expect(parts.count == data.count)
        }
    }

    @Test func parsesTheApiDigest() {
        #expect(ReleaseDigest.parse("sha256:\(abcDigest)") == abcDigest)
        #expect(ReleaseDigest.parse("sha256:\(abcDigest.uppercased())") == abcDigest)
    }

    @Test func rejectsOtherDigests() {
        for bad in [
            "", "sha256:", "sha256:abc", abcDigest, "sha1:\(abcDigest)", "sha256:\(abcDigest)0",
            "sha256:\(abcDigest.dropLast())",
            "sha256:\(String(repeating: "g", count: 64))", "SHA256:\(abcDigest)", "sha256: \(abcDigest)",
        ] {
            #expect(ReleaseDigest.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func comparesWithoutCase() {
        #expect(ReleaseDigest.matches(abcDigest, abcDigest.uppercased()))
        #expect(!ReleaseDigest.matches(abcDigest, emptyDigest))
        #expect(!ReleaseDigest.matches("", ""))
    }
}
