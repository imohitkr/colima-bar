import Darwin
import Foundation

/// The check of a backup file before a restore. It reads the whole file and
/// seeks over the file data, so it changes nothing and reads little.
enum TarFileScan {
    struct Summary: Equatable {
        /// The size of the file in bytes.
        let size: Int64
        /// The bytes of the ColimaBar entry. The Docker archive starts here.
        let skip: Int64
        let meta: VolumeBackupMeta?
        let entryCount: Int
    }

    enum Failure: Error, Equatable {
        case unreadable
        /// A gzip file. ColimaBar writes and restores plain tar only.
        case compressed
        case notComplete
        case unsafeEntry(String)
    }

    static func scan(path: String) throws -> Summary {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.unreadable }
        let size = Int64(st.st_size)
        var magic = [UInt8](repeating: 0, count: 2)
        if pread(fd, &magic, 2, 0) == 2, magic == [0x1F, 0x8B] { throw Failure.compressed }
        guard let head = VolumeBackupMeta.readHead(fd: fd) else { throw Failure.notComplete }

        var scanner = TarScanner()
        var offset = head.skip
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        do {
            while !scanner.isComplete {
                let skippable = scanner.skippable
                if skippable > 0 {
                    // The data of an entry needs no read. A cut file shows at its end.
                    guard offset + skippable <= size else { throw Failure.notComplete }
                    offset += skippable
                    scanner.skip(skippable)
                    continue
                }
                let want = min(max(scanner.wantsBytes, 1), buf.count)
                let n = pread(fd, &buf, want, off_t(offset))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw Failure.notComplete }
                offset += Int64(n)
                try scanner.feed(Data(buf[0..<n]))
            }
        } catch let e as TarScanner.Failure {
            switch e {
            case .unsafeEntry(let path): throw Failure.unsafeEntry(path)
            case .badHeader, .notComplete: throw Failure.notComplete
            }
        }
        return Summary(size: size, skip: head.skip, meta: head.meta, entryCount: scanner.entryCount)
    }
}
