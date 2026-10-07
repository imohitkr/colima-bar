import Foundation
import Testing

@testable import ColimaBar

@Suite struct LogDemuxerTests {
    private func frame(_ stream: UInt8, _ s: String) -> Data { LogFrame.make(stream, s) }

    private let max = LogDemuxer.maxLineBytes

    private let marker = LogDemuxer.splitMarker

    @Test func demuxesStdoutAndStderrFrames() {
        var d = LogDemuxer(tty: false)
        let lines = d.feed(frame(1, "hello\nwor") + frame(2, "oops\n") + frame(1, "ld\n"))
        #expect(lines.map(\.0) == ["hello", "oops", "world"])
        #expect(lines.map(\.1) == [false, true, false])
    }

    @Test func demuxHandlesFramesSplitAcrossReads() {
        var d = LogDemuxer(tty: false)
        let all = frame(1, "split line\n")
        #expect(d.feed(all.prefix(5)).isEmpty)
        #expect(d.feed(all.dropFirst(5).prefix(4)).isEmpty)
        #expect(d.feed(all.dropFirst(9)).map(\.0) == ["split line"])
    }

    @Test func ttyLogsAreRawText() {
        var d = LogDemuxer(tty: true)
        #expect(d.feed(Data("a\r\nb\n".utf8)).map(\.0) == ["a", "b"])
    }

    @Test func ttyKeepsMultibyteCharacterSplitAcrossReads() {
        var d = LogDemuxer(tty: true)
        let bytes = Data("héllo ✓\n".utf8)
        let cut = bytes.firstIndex(of: 0xC3)! + 1  // inside "é"
        #expect(d.feed(bytes.prefix(cut)).isEmpty)
        #expect(d.feed(bytes.dropFirst(cut)).map(\.0) == ["héllo ✓"])
    }

    @Test func framesKeepMultibyteCharacterSplitAcrossFrames() {
        var d = LogDemuxer(tty: false)
        let bytes = Data("✓ok\n".utf8)
        var first = frame(1, ""), second = frame(1, "")
        first.append(bytes.prefix(1))
        first[7] = 1  // first byte of "✓"
        second.append(bytes.dropFirst(1))
        second[7] = UInt8(bytes.count - 1)
        #expect(d.feed(first).isEmpty)
        #expect(d.feed(second).map(\.0) == ["✓ok"])
    }

    @Test func keepsEmptyLines() {
        var d = LogDemuxer(tty: true)
        #expect(d.feed(Data("a\n\nb\n".utf8)).map(\.0) == ["a", "", "b"])
    }

    @Test func splitsLongLineWithoutNewline() {
        var d = LogDemuxer(tty: true)
        let text = String(repeating: "a", count: max * 2 + 100)
        let first = d.feed(Data(text.utf8))
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.0 == String(repeating: "a", count: max) + marker })
        // The rest waits for its newline.
        #expect(d.feed(Data("\n".utf8)).map(\.0) == [String(repeating: "a", count: 100)])
    }

    @Test func splitsLongCompleteLine() {
        var d = LogDemuxer(tty: true)
        let out = d.feed(Data((String(repeating: "b", count: max + 5) + "\nnext\n").utf8))
        #expect(out.map(\.0) == [String(repeating: "b", count: max) + marker, "bbbbb", "next"])
    }

    @Test func doesNotCutMultibyteCharacters() {
        var d = LogDemuxer(tty: false)
        let text = String(repeating: "é", count: max) + "\n"  // 2 bytes each
        var frame = Data([1, 0, 0, 0, 0, 0, 0, 0])
        let payload = Data(text.utf8)
        frame[4] = UInt8(payload.count >> 24)
        frame[5] = UInt8(payload.count >> 16 & 0xff)
        frame[6] = UInt8(payload.count >> 8 & 0xff)
        frame[7] = UInt8(payload.count & 0xff)
        let out = d.feed(frame + payload)
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.0.contains("\u{FFFD}") })
        let joined = out.map { $0.0.replacingOccurrences(of: marker, with: "") }.joined()
        #expect(joined == String(repeating: "é", count: max))
    }

    @Test func manyFramesInOneReadStayInOrder() {
        var d = LogDemuxer(tty: false)
        var data = Data()
        for i in 0..<1000 {
            let p = Data("line \(i)\n".utf8)
            data += Data([i % 2 == 0 ? 1 : 2, 0, 0, 0, 0, 0, 0, UInt8(p.count)]) + p
        }
        let out = d.feed(data.prefix(5000))
        let rest = d.feed(data.dropFirst(5000))
        let all = out + rest
        #expect(all.map(\.0) == (0..<1000).map { "line \($0)" })
        #expect(all.map(\.1) == (0..<1000).map { $0 % 2 == 1 })
    }
}
