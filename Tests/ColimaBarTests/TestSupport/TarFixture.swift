import Foundation

@testable import ColimaBar

/// Builds tar archives for tests, byte by byte.
enum TarFixture {
    static let endMarker = Data(repeating: 0, count: 1024)

    static func entry(
        _ name: String, content: String = "", flag: UInt8 = 0x30, linkName: String = ""
    ) -> Data {
        let data = Data(content.utf8)
        return TarHeader.block(name: name, size: Int64(data.count), flag: flag, linkName: linkName) + data
            + Data(repeating: 0, count: Int(TarHeader.padded(Int64(data.count))) - data.count)
    }

    static func directory(_ name: String) -> Data { TarHeader.block(name: name, flag: 0x35, mode: 0o755) }

    /// A PAX `x` header with the records `path`, `linkpath` or `size`.
    static func pax(_ records: [String: String]) -> Data {
        var body = Data()
        for (key, value) in records.sorted(by: { $0.key < $1.key }) {
            let rest = " \(key)=\(value)\n"
            var length = rest.utf8.count + 1
            while String(length).utf8.count + rest.utf8.count != length {
                length = String(length).utf8.count + rest.utf8.count
            }
            body += Data("\(length)\(rest)".utf8)
        }
        return TarHeader.block(name: "PaxHeader", size: Int64(body.count), flag: 0x78) + body
            + Data(repeating: 0, count: Int(TarHeader.padded(Int64(body.count))) - body.count)
    }

    /// A GNU long name (`L`) or long link name (`K`) header.
    static func gnuLong(_ text: String, flag: UInt8 = 0x4C) -> Data {
        let body = Data(text.utf8) + Data([0])
        return TarHeader.block(name: "././@LongLink", size: Int64(body.count), flag: flag) + body
            + Data(repeating: 0, count: Int(TarHeader.padded(Int64(body.count))) - body.count)
    }

    /// The archive that Docker sends for a volume with a file `f` and a folder `sub`.
    static func volume(files: [(String, String)] = [("v/f", "hi")]) -> Data {
        var tar = directory("v/")
        for (name, content) in files { tar += entry(name, content: content) }
        return tar + endMarker
    }
}
