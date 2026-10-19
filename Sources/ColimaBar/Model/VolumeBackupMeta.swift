import Foundation

/// The first entry of a backup file: `.colimabar-volume.json`. It holds the
/// facts of the volume. The Docker archive follows it unchanged, so a restore
/// skips this entry by its byte size. A tar tool can still read the file.
struct VolumeBackupMeta: Codable, Equatable {
    static let entryName = ".colimabar-volume.json"
    /// The largest data of the entry. A restore reads at most this much.
    static let maxData = 64 * 1024
    static let maxLabels = 64
    static let maxLabelText = 1024

    var format = 1
    var name: String
    var driver: String
    var labels: [String: String]
    var created: String
    var app: String

    init(
        name: String, driver: String = "local", labels: [String: String] = [:], created: String = "",
        app: String = "ColimaBar"
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.created = created
        self.app = app
    }

    /// The tar entry: header, JSON data and padding. If the JSON is more than
    /// 64 KB, the entry leaves out the labels.
    func entry() -> Data {
        var json = Self.encode(self)
        if json.count > Self.maxData {
            var plain = self
            plain.labels = [:]
            json = Self.encode(plain)
        }
        let padding = Int(TarHeader.padded(Int64(json.count))) - json.count
        return TarHeader.block(name: Self.entryName, size: Int64(json.count), mode: 0o600) + json
            + Data(repeating: 0, count: padding)
    }

    /// The labels for a restore into a volume named `target`. A volume with
    /// another name gets none: the compose labels would tie it to a project.
    func labels(forTarget target: String) -> [String: String] {
        guard target == name, labels.count <= Self.maxLabels else { return [:] }
        return labels.filter { $0.key.count <= Self.maxLabelText && $0.value.count <= Self.maxLabelText }
    }

    private static func encode(_ meta: VolumeBackupMeta) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(meta)) ?? Data()
    }

    /// What the start of a file holds.
    struct Head: Equatable {
        /// The facts of the volume. Nil if the file has no entry, or if its
        /// JSON is not valid.
        let meta: VolumeBackupMeta?
        /// The number of bytes of the entry. The Docker archive starts here.
        let skip: Int64
    }

    /// Reads the start of a file. A file without the entry (for example, an
    /// archive from `docker cp`) gives `skip` 0. Nil if the entry is too big.
    static func readHead(fd: Int32) -> Head? {
        var block = [UInt8](repeating: 0, count: TarHeader.blockSize)
        guard pread(fd, &block, block.count, 0) == block.count, let h = TarHeader.parse(block),
            h.name == entryName, h.kind == .file
        else { return Head(meta: nil, skip: 0) }
        guard h.size <= Int64(maxData) else { return nil }
        var data = [UInt8](repeating: 0, count: Int(h.size))
        guard h.size == 0 || pread(fd, &data, data.count, off_t(TarHeader.blockSize)) == data.count else {
            return nil
        }
        let meta = try? JSONDecoder().decode(VolumeBackupMeta.self, from: Data(data))
        return Head(meta: meta, skip: Int64(TarHeader.blockSize) + TarHeader.padded(h.size))
    }
}
