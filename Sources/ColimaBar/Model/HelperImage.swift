import CryptoKit
import Foundation

/// The helper image of the volume backup. ColimaBar builds it on the Mac as a
/// `docker save` archive of about 3 KB and loads it with `POST /images/load`.
/// Thus it pulls nothing, needs no network and has no rate limit.
///
/// The image has one empty folder, `/v`. No container ever starts from it:
/// the helper container is only created, because the archive calls of the
/// Docker API work on a created container.
enum HelperImage {
    static let tag = "colimabar-helper:1"
    static let label = "com.imohitkr.colimabar.helper"
    static let kindLabel = "com.imohitkr.colimabar.helper.kind"
    static let kind = "volume"

    /// The labels of a helper container. Clean-up looks for both.
    static var labels: [String: String] { [label: "1", kindLabel: kind] }

    /// True if the labels mark a helper container (the Containers tab hides it).
    static func isHelper(labels: [String: String]?) -> Bool { labels?[label] == "1" }

    /// The label filter for a list call: only containers with both labels.
    static var labelFilter: String {
        let filters: [String: [String]] = ["label": ["\(label)=1", "\(kindLabel)=\(kind)"]]
        let data = (try? JSONSerialization.data(withJSONObject: filters, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The architecture name of the image for the `Architecture` that
    /// `GET /info` gives: `aarch64` and `x86_64` map to `arm64` and `amd64`.
    static func architecture(info: String?) -> String {
        switch info {
        case "aarch64", "arm64": "arm64"
        case "x86_64", "amd64": "amd64"
        case let other?: other
        case nil: "arm64"
        }
    }

    /// The `docker save` archive: `manifest.json`, `config.json` and
    /// `layer.tar`. The bytes depend only on `arch`.
    static func archive(arch: String) -> Data {
        let layer = TarHeader.block(name: "v/", flag: 0x35, mode: 0o755) + endMarker
        let diffID = "sha256:" + hex(SHA256.hash(data: layer))
        let config = json([
            "architecture": arch,
            "os": "linux",
            "created": "1970-01-01T00:00:00Z",
            "config": [String: String](),
            "rootfs": ["type": "layers", "diff_ids": [diffID]] as [String: Any],
        ])
        let manifest = json([["Config": "config.json", "RepoTags": [tag], "Layers": ["layer.tar"]] as [String: Any]])
        return file("manifest.json", manifest) + file("config.json", config) + file("layer.tar", layer) + endMarker
    }

    /// The request body of `POST /containers/create`. The helper is never
    /// started. `readOnly` is true for a backup.
    static func containerBody(volume: String, readOnly: Bool) -> Data {
        let mount: [String: Any] = ["Type": "volume", "Source": volume, "Target": "/v", "ReadOnly": readOnly]
        return json([
            "Image": tag,
            "Cmd": ["/none"],
            "NetworkDisabled": true,
            "Labels": labels,
            "HostConfig": ["Mounts": [mount]] as [String: Any],
        ])
    }

    // MARK: - Tar

    private static let endMarker = Data(repeating: 0, count: 2 * TarHeader.blockSize)

    private static func file(_ name: String, _ data: Data) -> Data {
        let padding = Int(TarHeader.padded(Int64(data.count))) - data.count
        return TarHeader.block(name: name, size: Int64(data.count)) + data + Data(repeating: 0, count: padding)
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
