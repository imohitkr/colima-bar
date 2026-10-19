import Foundation

/// One 512-byte tar header block. `parse` reads ustar, PAX and GNU blocks,
/// and `block` builds a ustar block. Only the fields that ColimaBar needs are
/// kept.
struct TarHeader: Equatable {
    static let blockSize = 512

    enum Kind: Equatable {
        case file, hardLink, symlink, charDevice, blockDevice, directory, fifo
        /// A PAX header for the next entry (`x`) or for the whole archive (`g`).
        case paxLocal, paxGlobal
        /// GNU long name (`L`) and long link name (`K`) for the next entry.
        case gnuLongName, gnuLongLink
        case other(UInt8)

        init(flag: UInt8) {
            switch flag {
            case 0, 0x30, 0x37: self = .file  // NUL, "0", "7"
            case 0x31: self = .hardLink
            case 0x32: self = .symlink
            case 0x33: self = .charDevice
            case 0x34: self = .blockDevice
            case 0x35: self = .directory
            case 0x36: self = .fifo
            case 0x78: self = .paxLocal  // "x"
            case 0x67: self = .paxGlobal  // "g"
            case 0x4C: self = .gnuLongName  // "L"
            case 0x4B: self = .gnuLongLink  // "K"
            default: self = .other(flag)
            }
        }

        /// True if the data after the header belongs to this entry.
        var hasData: Bool {
            switch self {
            case .file, .other: true
            default: false
            }
        }
    }

    let name: String
    let size: Int64
    let kind: Kind
    let linkName: String

    /// True if every byte of the block is zero (part of the end marker).
    static func isZero(_ block: [UInt8]) -> Bool { !block.contains { $0 != 0 } }

    /// Reads a block. It gives nil if the checksum or a number is wrong.
    static func parse(_ block: [UInt8]) -> TarHeader? {
        guard block.count == blockSize, checksumMatches(block), let size = number(block, 124, 12), size >= 0 else {
            return nil
        }
        var name = text(block, 0, 100)
        // The prefix field exists in the POSIX format only. The GNU format
        // (magic "ustar  ") uses these bytes for other values.
        if Array(block[257..<263]) == Array("ustar\0".utf8) {
            let prefix = text(block, 345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        return TarHeader(name: name, size: size, kind: Kind(flag: block[156]), linkName: text(block, 157, 100))
    }

    /// Builds a ustar block. A name or link name of more than 100 bytes is cut.
    static func block(
        name: String, size: Int64 = 0, flag: UInt8 = 0x30, mode: Int = 0o644, mtime: Int = 0, linkName: String = ""
    ) -> Data {
        var b = [UInt8](repeating: 0, count: blockSize)
        put(&b, 0, 100, Array(name.utf8))
        put(&b, 100, 8, octal(mode, width: 7))
        put(&b, 108, 8, octal(0, width: 7))
        put(&b, 116, 8, octal(0, width: 7))
        put(&b, 124, 12, octal(Int(size), width: 11))
        put(&b, 136, 12, octal(mtime, width: 11))
        b[156] = flag
        put(&b, 157, 100, Array(linkName.utf8))
        put(&b, 257, 6, Array("ustar\0".utf8))
        put(&b, 263, 2, Array("00".utf8))
        for i in 148..<156 { b[i] = 0x20 }
        let sum = b.reduce(0) { $0 + Int($1) }
        put(&b, 148, 8, octal(sum, width: 6) + [0, 0x20])
        return Data(b)
    }

    /// The number of bytes that hold `size` bytes of data, with the padding.
    static func padded(_ size: Int64) -> Int64 { (size + 511) / 512 * 512 }

    // MARK: - Fields

    private static func put(_ b: inout [UInt8], _ at: Int, _ width: Int, _ bytes: [UInt8]) {
        for (i, byte) in bytes.prefix(width).enumerated() { b[at + i] = byte }
    }

    private static func octal(_ value: Int, width: Int) -> [UInt8] {
        let digits = Array(String(value, radix: 8).utf8)
        return [UInt8](repeating: 0x30, count: max(0, width - digits.count)) + digits
    }

    private static func text(_ b: [UInt8], _ at: Int, _ width: Int) -> String {
        let field = b[at..<(at + width)]
        return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// An octal number, or a GNU base-256 number if the first bit is set.
    private static func number(_ b: [UInt8], _ at: Int, _ width: Int) -> Int64? {
        let field = Array(b[at..<(at + width)])
        if field[0] & 0x80 != 0 {
            var value: Int64 = Int64(field[0] & 0x7F)
            for byte in field.dropFirst() {
                guard value < (Int64.max >> 8) else { return nil }
                value = value << 8 | Int64(byte)
            }
            return value
        }
        let digits = field.drop { $0 == 0x20 }.prefix { $0 != 0 && $0 != 0x20 }
        if digits.isEmpty { return 0 }
        var value: Int64 = 0
        for d in digits {
            guard d >= 0x30, d <= 0x37, value < (Int64.max >> 3) else { return nil }
            value = value << 3 | Int64(d - 0x30)
        }
        return value
    }

    private static func checksumMatches(_ b: [UInt8]) -> Bool {
        guard let stored = number(b, 148, 8) else { return false }
        var unsigned = 0
        var signed = 0
        for (i, byte) in b.enumerated() {
            let v = (148..<156).contains(i) ? 0x20 : byte
            unsigned += Int(v)
            signed += Int(Int8(bitPattern: v))
        }
        return stored == Int64(unsigned) || stored == Int64(signed)
    }
}
