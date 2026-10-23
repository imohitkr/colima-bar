import Foundation

/// A streaming check of a tar archive of a volume. It reads ustar headers,
/// PAX `x` records (`path`, `linkpath`, `size`) and GNU long names. It skips
/// the data of each entry and checks each header. It never stores file data.
///
/// With `Names.volume` (the default), every name must be `v` or start with
/// `v/`, because the helper container mounts the volume at `/v`. With
/// `Names.any` (a `docker save` archive of images), a name only must not start
/// with `/` or have a `..` part. A name with `..` or a leading `/`, a device, or
/// a hard link to a target outside `v/` is unsafe. A symlink target is not
/// checked: Docker extracts in a chroot, so a link cannot leave the volume.
/// The archive is complete only after its end marker (two zero blocks).
struct TarScanner {
    enum Failure: Error, Equatable {
        /// A header with a wrong checksum or number, or an oversize record.
        case badHeader
        /// An entry that must not go into a volume. The value is its name.
        case unsafeEntry(String)
        /// The archive ended before its end marker.
        case notComplete
    }

    private enum Collect { case pax, longName, longLink }
    private enum State {
        case header
        case collect(Collect, size: Int)
        case skip(Int64)
        case done
    }

    /// Which names the scanner accepts.
    enum Names: Equatable, Sendable {
        /// The archive of a volume: `v` and `v/…`.
        case volume
        /// The archive of images: any relative name without `..`.
        case any
    }

    /// The most bytes of one PAX or GNU record that the scanner holds.
    static let maxRecord = 1 << 20

    private(set) var isComplete = false
    private(set) var entryCount = 0
    /// True after an entry other than the root folder `v/`.
    private(set) var sawContent = false
    private var state = State.header
    private var buffer: [UInt8] = []
    private var zeroBlocks = 0
    private var pendingPath: String?
    private var pendingLink: String?
    private var pendingSize: Int64?
    private let names: Names

    init(names: Names = .volume) { self.names = names }

    /// True for `v`, `v/` and every path below `v/`, with no `..` part and no
    /// leading `/`.
    static func isSafe(_ path: String, names: Names = .volume) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        if names == .volume { guard path == "v" || path.hasPrefix("v/") else { return false } }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isRoot(_ path: String) -> Bool {
        var p = Substring(path)
        while p.hasSuffix("/") { p = p.dropLast() }
        return p == "v"
    }

    mutating func feed(_ data: Data) throws {
        guard !isComplete else { return }
        buffer.append(contentsOf: data)
        var pos = 0
        defer { buffer.removeFirst(pos) }
        while true {
            switch state {
            case .done:
                return
            case .header:
                guard buffer.count - pos >= TarHeader.blockSize else { return }
                let block = Array(buffer[pos..<(pos + TarHeader.blockSize)])
                pos += TarHeader.blockSize
                try header(block)
            case .collect(let what, let size):
                let total = Int(TarHeader.padded(Int64(size)))
                guard buffer.count - pos >= total else { return }
                let record = Array(buffer[pos..<(pos + size)])
                pos += total
                try apply(what, record)
                state = .header
            case .skip(let remaining):
                let n = min(remaining, Int64(buffer.count - pos))
                pos += Int(n)
                state = n == remaining ? .header : .skip(remaining - n)
                if n < remaining { return }
            }
        }
    }

    /// Throws `notComplete` if the end marker did not arrive.
    func finish() throws {
        guard isComplete else { throw Failure.notComplete }
    }

    /// The number of bytes that the scanner drops without a look. A reader of
    /// a file can seek over them.
    var skippable: Int64 {
        if case .skip(let n) = state, buffer.isEmpty { return n }
        return 0
    }

    /// Tells the scanner that the reader seeked over `count` skippable bytes.
    mutating func skip(_ count: Int64) {
        guard case .skip(let n) = state, buffer.isEmpty else { return }
        state = count >= n ? .header : .skip(n - count)
    }

    /// The number of bytes to read next so that the scanner can go on.
    var wantsBytes: Int {
        switch state {
        case .header: max(1, TarHeader.blockSize - buffer.count)
        case .collect(_, let size): max(1, Int(TarHeader.padded(Int64(size))) - buffer.count)
        case .skip, .done: 1
        }
    }

    // MARK: - Headers

    private mutating func header(_ block: [UInt8]) throws {
        if TarHeader.isZero(block) {
            zeroBlocks += 1
            if zeroBlocks >= 2 {
                isComplete = true
                state = .done
            }
            return
        }
        zeroBlocks = 0
        guard let h = TarHeader.parse(block) else { throw Failure.badHeader }
        switch h.kind {
        case .paxLocal: try startCollect(.pax, h.size)
        case .gnuLongName: try startCollect(.longName, h.size)
        case .gnuLongLink: try startCollect(.longLink, h.size)
        case .paxGlobal: state = .skip(TarHeader.padded(h.size))
        default: try entry(h)
        }
    }

    private mutating func startCollect(_ what: Collect, _ size: Int64) throws {
        guard size <= Int64(Self.maxRecord) else { throw Failure.badHeader }
        state = .collect(what, size: Int(size))
    }

    private mutating func entry(_ h: TarHeader) throws {
        let name = pendingPath ?? h.name
        let link = pendingLink ?? h.linkName
        let size = pendingSize ?? h.size
        pendingPath = nil
        pendingLink = nil
        pendingSize = nil
        guard Self.isSafe(name, names: names) else { throw Failure.unsafeEntry(name) }
        switch h.kind {
        case .charDevice, .blockDevice: throw Failure.unsafeEntry(name)
        case .hardLink: guard Self.isSafe(link, names: names) else { throw Failure.unsafeEntry(name) }
        default: break
        }
        entryCount += 1
        if !Self.isRoot(name) { sawContent = true }
        state = h.kind.hasData && size > 0 ? .skip(TarHeader.padded(size)) : .header
    }

    private mutating func apply(_ what: Collect, _ record: [UInt8]) throws {
        switch what {
        case .longName: pendingPath = Self.cString(record)
        case .longLink: pendingLink = Self.cString(record)
        case .pax: try pax(record)
        }
    }

    private static func cString(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Reads the records `LENGTH KEY=VALUE\n` of a PAX header.
    private mutating func pax(_ data: [UInt8]) throws {
        var i = 0
        while i < data.count {
            guard let space = data[i...].firstIndex(of: 0x20),
                let length = Int(String(decoding: data[i..<space], as: UTF8.self)),
                length > space - i + 1, i + length <= data.count, data[i + length - 1] == 0x0A
            else { throw Failure.badHeader }
            let body = data[(space + 1)..<(i + length - 1)]
            if let eq = body.firstIndex(of: 0x3D) {
                let key = String(decoding: body[body.startIndex..<eq], as: UTF8.self)
                let value = String(decoding: body[(eq + 1)...], as: UTF8.self)
                switch key {
                case "path": pendingPath = value
                case "linkpath": pendingLink = value
                case "size":
                    guard let n = Int64(value), n >= 0 else { throw Failure.badHeader }
                    pendingSize = n
                default: break
                }
            }
            i += length
        }
    }
}
