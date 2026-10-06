import Foundation
import Testing

@testable import ColimaBar

@Suite struct ByteFormatTests {
    @Test func formatsBytes() {
        #expect(Fmt.bytes(0) == "0 B")
        #expect(Fmt.bytes(512) == "512 B")
        #expect(Fmt.bytes(1536) == "1.5 KB")
        #expect(Fmt.bytes(5 * 1024 * 1024 * 1024) == "5.0 GB")
        #expect(Fmt.bytes(250 * 1024 * 1024) == "250 MB")
    }
}
