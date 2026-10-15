import Foundation

/// Changes the docker CLI config file for a Doctor fix. It makes a backup
/// first and writes through a symlink.
enum DockerConfigFile {
    enum Outcome: Equatable {
        /// The file has the new content. `backup` is nil if there was no file.
        case changed(backup: String?)
        /// The file is not a JSON object. Nothing changed.
        case invalid
        case failed(String)
    }

    /// What reading the file gives. A file that exists but cannot be read
    /// (for example owned by root, mode 0600, after `sudo docker login`) is
    /// not a missing file: a write would replace its content.
    enum Content: Equatable {
        case missing
        case data(Data)
        case unreadable
    }

    /// Reads the target of `path`, following links.
    static func read(path: String) -> Content {
        let target = SymlinkWrite.target(of: path)
        guard (try? FileManager.default.attributesOfItem(atPath: target)) != nil else { return .missing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target)) else { return .unreadable }
        return .data(data)
    }

    /// `config.json.colimabar-YYYYMMDD-HHMMSS`, in the folder of the file.
    static func backupPath(for target: String, now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(target).colimabar-\(f.string(from: now))"
    }

    /// Reads the file (a missing file is empty), applies `transform` and
    /// writes the result. `transform` returns nil for a file it cannot change.
    /// A file that exists but cannot be read is never written.
    static func edit(
        path: String, now: Date = Date(), timeZone: TimeZone = .current, _ transform: (Data) -> Data?
    ) -> Outcome {
        let fm = FileManager.default
        let target = SymlinkWrite.target(of: path)
        var existing: Data?
        switch read(path: path) {
        case .missing: existing = nil
        case .data(let data): existing = data
        case .unreadable: return .failed("Cannot read \(target). ColimaBar did not change it.")
        }
        guard let updated = transform(existing ?? Data()) else { return .invalid }
        var backup: String?
        do {
            if let existing {
                let b = backupPath(for: target, now: now, timeZone: timeZone)
                guard fm.createFile(atPath: b, contents: existing, attributes: [.posixPermissions: 0o600]) else {
                    return .failed("Cannot write the backup \(b).")
                }
                backup = b
            } else {
                try fm.createDirectory(
                    atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            }
            try SymlinkWrite.write(updated, to: path)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .changed(backup: backup)
    }
}
