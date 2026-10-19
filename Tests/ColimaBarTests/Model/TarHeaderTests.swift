import Foundation
import Testing

@testable import ColimaBar

@Suite struct TarHeaderTests {
    @Test func aBuiltBlockParsesBack() {
        let block = Array(TarHeader.block(name: "v/file.txt", size: 1234))
        let h = TarHeader.parse(block)
        #expect(h == TarHeader(name: "v/file.txt", size: 1234, kind: .file, linkName: ""))
    }

    @Test func aSymlinkKeepsItsTarget() {
        let block = Array(TarHeader.block(name: "v/l", flag: 0x32, linkName: "../../etc/passwd"))
        let h = TarHeader.parse(block)
        #expect(h?.kind == .symlink && h?.linkName == "../../etc/passwd")
    }

    @Test func aChangedByteBreaksTheChecksum() {
        var block = Array(TarHeader.block(name: "v/f", size: 1))
        block[0] = 0x77
        #expect(TarHeader.parse(block) == nil)
    }

    @Test func aBlockOfZeroBytesIsZero() {
        #expect(TarHeader.isZero([UInt8](repeating: 0, count: 512)))
        #expect(!TarHeader.isZero(Array(TarHeader.block(name: "v/"))))
    }

    @Test func aWrongBlockLengthIsNotAHeader() {
        #expect(TarHeader.parse([UInt8](repeating: 0, count: 100)) == nil)
    }

    @Test func theUstarPrefixJoinsTheName() {
        var block = Array(TarHeader.block(name: "file", size: 0))
        for (i, byte) in Array("v/deep/folder".utf8).enumerated() { block[345 + i] = byte }
        for i in 148..<156 { block[i] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        let digits = Array(String(sum, radix: 8).utf8)
        let field = [UInt8](repeating: 0x30, count: 6 - digits.count) + digits + [0, 0x20]
        for (i, byte) in field.enumerated() { block[148 + i] = byte }
        #expect(TarHeader.parse(block)?.name == "v/deep/folder/file")
    }

    @Test func aBase256SizeIsRead() {
        var block = Array(TarHeader.block(name: "v/big", size: 0))
        block[124] = 0x80
        for i in 125..<136 { block[i] = 0 }
        block[135] = 0x10
        for i in 148..<156 { block[i] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        let digits = Array(String(sum, radix: 8).utf8)
        let field = [UInt8](repeating: 0x30, count: 6 - digits.count) + digits + [0, 0x20]
        for (i, byte) in field.enumerated() { block[148 + i] = byte }
        #expect(TarHeader.parse(block)?.size == 16)
    }

    @Test func paddedRoundsUpToWholeBlocks() {
        #expect(TarHeader.padded(0) == 0)
        #expect(TarHeader.padded(1) == 512)
        #expect(TarHeader.padded(512) == 512)
        #expect(TarHeader.padded(513) == 1024)
    }
}
