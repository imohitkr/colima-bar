import Foundation

/// Why ColimaBar did not stage the new colima.yaml.
enum VMSettingsFailure: Error, LocalizedError, Equatable {
    case notText
    /// The staged file could not be written. `reason` comes from the system.
    case notWritten(path: String, reason: String)
    case problems([String])
    /// colima.yaml is not the file that the form was filled from.
    case changedOutside

    var errorDescription: String? {
        switch self {
        case .notText: "colima.yaml is not UTF-8 text."
        case .notWritten(let path, let reason): "ColimaBar could not write \(path): \(reason)."
        case .problems(let list): list.joined(separator: " ")
        case .changedOutside:
            "colima.yaml changed outside ColimaBar. ColimaBar reloaded it. Check your changes and click Apply again."
        }
    }
}
