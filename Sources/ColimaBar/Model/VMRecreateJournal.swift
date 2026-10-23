import Foundation

/// The record of a VM type change that runs or did not finish. ColimaBar
/// writes it to `~/.cache/colima-bar/recreate.PROFILE.json` before the VM
/// changes. If the app quits during the change, the next launch reads it and
/// tells the user what is left to do. It holds names and image references,
/// no secrets and no environment.
struct VMRecreateJournal: Codable, Equatable, Sendable {
    static let format = "colimabar-recreate"
    static let version = 1

    struct Types: Codable, Equatable, Sendable {
        var vmType: String
        var mountType: String
    }

    enum Phase: String, Codable, Sendable {
        /// The backups run. Nothing in the VM has changed.
        case backup
        /// The script deletes and creates the VM.
        case recreate
        /// The VM changed. Volumes and images may need a restore.
        case restore
    }

    struct Volume: Codable, Equatable, Sendable {
        var name: String
        /// The last path component of the backup file.
        var file: String
    }

    var format = Self.format
    var version = Self.version
    var profile: String
    var from: Types
    var to: Types
    /// The full path of the backup folder, or "" if no backup was made.
    var folder: String
    var created: Date
    var phase: Phase
    var volumes: [Volume] = []
    /// "images.tar" if the images were saved.
    var imagesFile: String?
    var imagesSHA256: String?
    /// The references that were saved.
    var images: [String] = []

    /// The name of the backup folder, without its path.
    var folderName: String { (folder as NSString).lastPathComponent }

    /// Reads a journal. A wrong format or version, or an invalid profile name,
    /// gives nil.
    static func load(_ data: Data) -> VMRecreateJournal? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let j = try? decoder.decode(VMRecreateJournal.self, from: data),
            j.format == format, j.version == version, ProfileName.isValid(j.profile),
            j.volumes.allSatisfy({ isPlainFileName($0.file) && isVolumeName($0.name) }),
            j.folder.isEmpty || isAbsolutePath(j.folder),
            j.imagesFile.map(isPlainFileName) ?? true,
            j.imagesSHA256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true
        else { return nil }
        return j
    }

    /// True for a name that Docker accepts for a volume.
    static func isVolumeName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    /// True for a full path with no `..` part.
    static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// True for a name with no path: the files of the backup folder only.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    enum Recovery: Equatable {
        /// The change stopped before the VM changed.
        case nothingChanged
        /// The VM changed. Volumes and images may be missing.
        case restorePending
        /// The change stopped after the delete, and colima.yaml is gone.
        case configMissing
    }

    /// What the notice says. `now` is colima.yaml now, or nil if the file is
    /// missing. `busy` is true while an action of the profile runs: then the
    /// journal belongs to that action, and the result is nil.
    static func recovery(_ j: VMRecreateJournal, now read: VMSettings.Read?, busy: Bool) -> Recovery? {
        if busy { return nil }
        switch j.phase {
        case .backup: return .nothingChanged
        case .restore: return .restorePending
        case .recreate:
            guard let read else { return .configMissing }
            let now = VMTypeRules.effective(vmType: read.vmType, mountType: read.mountType)
            if now == (j.to.vmType, j.to.mountType) { return .restorePending }
            return .nothingChanged
        }
    }
}
