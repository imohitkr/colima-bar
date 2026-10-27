import Darwin
import Foundation

/// The layout of an image archive. `docker save` writes a `manifest.json` in
/// the root. The containerd image store can write an OCI layout, which has
/// `index.json` and may have no `manifest.json`. Grype needs the layout in
/// the name of its source. Trivy reads both.
enum ImageArchiveLayout: Equatable, Sendable {
    case docker, oci

    /// Reads the headers of the file and seeks over the data. A file that it
    /// cannot read, or that has neither name, counts as `docker`.
    static func detect(path: String) -> ImageArchiveLayout {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return .docker }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .docker }
        let size = Int64(st.st_size)
        var offset: Int64 = 0
        var sawIndex = false
        var block = [UInt8](repeating: 0, count: TarHeader.blockSize)
        while offset + Int64(TarHeader.blockSize) <= size {
            guard pread(fd, &block, block.count, off_t(offset)) == block.count, !TarHeader.isZero(block),
                let header = TarHeader.parse(block)
            else { break }
            let name = header.name.hasPrefix("./") ? String(header.name.dropFirst(2)) : header.name
            if header.kind.hasData {
                if name == "manifest.json" { return .docker }
                if name == "index.json" { sawIndex = true }
            }
            offset +=
                Int64(TarHeader.blockSize) + TarHeader.padded(header.kind.hasData || isPax(header) ? header.size : 0)
        }
        return sawIndex ? .oci : .docker
    }

    /// PAX and GNU long name headers carry their data after the header.
    private static func isPax(_ header: TarHeader) -> Bool {
        switch header.kind {
        case .paxLocal, .paxGlobal, .gnuLongName, .gnuLongLink: true
        default: false
        }
    }
}
