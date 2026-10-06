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
}
