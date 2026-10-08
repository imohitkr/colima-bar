import Foundation
import Testing

@testable import ColimaBar

@Suite struct ByteFormatTests {
    @Test func formatsBytes() {
        #expect(ByteFormat.bytes(0) == "0 B")
        #expect(ByteFormat.bytes(512) == "512 B")
        #expect(ByteFormat.bytes(1536) == "1.5 KB")
        #expect(ByteFormat.bytes(5 * 1024 * 1024 * 1024) == "5.0 GB")
        #expect(ByteFormat.bytes(250 * 1024 * 1024) == "250 MB")
    }

    @Test func formatsGiBWithoutATrailingZero() {
        #expect(ByteFormat.gibText(8) == "8")
        #expect(ByteFormat.gibText(2.5) == "2.5")
        #expect(ByteFormat.gibText(0.5) == "0.5")
        #expect(ByteFormat.gibText(3.25) == "3.25")
    }

    @Test func convertsBytesToADecimalGiB() {
        #expect(ByteFormat.gib(bytes: 8 << 30) == 8)
        #expect(ByteFormat.gib(bytes: 5 << 29) == 2.5)
        // 0.3 GiB as whole MiB (307 MiB) reads as 0.3.
        #expect(ByteFormat.gib(bytes: 307 << 20) == 0.3)
        #expect(ByteFormat.gib(bytes: 0) == 0)
    }
}
