import Darwin
import Foundation

/// Where `colimabar diagnostics` writes the file. The command never
/// overwrites a file or follows a link that is already there.
enum CLIDiagnosticsPath {
    enum Failure: Error, Equatable {
        /// A file, a link or another item is at the path.
        case exists(String)
        /// The folder for the file is missing.
        case folderMissing(String)

        var message: String {
            switch self {
            case .exists(let path): "\(path) exists. ColimaBar does not overwrite it."
            case .folderMissing(let path): "The folder \(path) does not exist."
            }
        }
    }

    /// The file for `argument`: nil means the current folder `cwd`. A folder
    /// gets the file name of `DiagnosticsBundle.fileName`. Another path is
    /// the file. A relative path starts in `cwd`.
    static func resolve(argument: String?, cwd: String, date: Date, timeZone: TimeZone = .current) -> Result<
        URL, Failure
    > {
        let name = DiagnosticsBundle.fileName(date: date, timeZone: timeZone)
        let absolute: (String) -> String = { $0.hasPrefix("/") ? $0 : "\(cwd)/\($0)" }
        let target: String
        if let argument {
            let full = absolute(argument)
            // stat, not lstat: a link to a folder is a folder.
            var info = stat()
            if stat(full, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                target = (full as NSString).appendingPathComponent(name)
            } else {
                target = full
            }
        } else {
            target = (cwd as NSString).appendingPathComponent(name)
        }
        var existing = stat()
        // lstat: a link counts as an item, also when it points nowhere.
        if lstat(target, &existing) == 0 { return .failure(.exists(target)) }
        let folder = (target as NSString).deletingLastPathComponent
        var folderInfo = stat()
        guard stat(folder, &folderInfo) == 0, folderInfo.st_mode & S_IFMT == S_IFDIR else {
            return .failure(.folderMissing(folder))
        }
        return .success(URL(fileURLWithPath: target))
    }
}
