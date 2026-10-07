import Foundation

/// The settings file for export and import. It is JSON with a format name
/// and a version:
///
///     {"format": "colimabar-settings", "version": 1, "app": "0.5.0",
///      "settings": {"autoStart": true, "autoStopMinutes": 30, ...}}
///
/// The file holds only user settings. Internal one-time keys (for example
/// `toldIconHidden` or `apiVersion`) never go into it. The functions here
/// are pure, so tests can call them. `ColimaModel+Settings` reads and
/// applies the values.
enum SettingsTransfer {
    static let format = "colimabar-settings"
    /// The file version that this app writes. It reads this version and older ones.
    static let version = 1
    static let fileName = "ColimaBar-settings.json"
    /// A settings file is less than 1 KB. A larger file is not one.
    static let maxBytes = 64 * 1024

    /// A setting in the file. The raw value is the JSON key. For all
    /// settings except `launchAtLogin`, it is also the `Defaults.Key`.
    enum Setting: String, CaseIterable, Sendable {
        case autoStart
        case autoStop
        case autoStopMinutes
        case hideIconWhenStopped
        case notifyOnCrash
        case keepRemovedLogs
        case checkUpdates
        case profile
        case launchAtLogin

        /// The name that the confirmation and the summary show.
        var title: String {
            switch self {
            case .autoStart: "Auto-start"
            case .autoStop: "Auto-stop"
            case .autoStopMinutes: "Auto-stop time"
            case .hideIconWhenStopped: "Hide the icon while Colima is stopped"
            case .notifyOnCrash: "Crash notifications"
            case .keepRemovedLogs: "Keep logs of removed containers"
            case .checkUpdates: "Daily version check"
            case .profile: "Profile"
            case .launchAtLogin: "Launch at login"
            }
        }
    }

    enum Value: Equatable, Sendable {
        case bool(Bool)
        case int(Int)
        case string(String)

        var json: Any {
            switch self {
            case .bool(let b): b
            case .int(let n): n
            case .string(let s): s
            }
        }

        /// The value as the confirmation shows it.
        func text(for s: Setting) -> String {
            switch self {
            case .bool(let b): b ? "on" : "off"
            case .int(let n): s == .autoStopMinutes ? "\(n) min" : "\(n)"
            case .string(let v): v
            }
        }
    }

    typealias Snapshot = [Setting: Value]

    /// One setting that the import changes.
    struct Change: Equatable, Sendable {
        let setting: Setting
        let from: Value?
        let to: Value

        var text: String {
            let old = from.map { $0.text(for: setting) } ?? "not set"
            return "\(setting.title): \(old) → \(to.text(for: setting))"
        }
    }

    /// What an import does: the changes to apply, and a note for each value
    /// that it skips.
    struct Plan: Equatable, Sendable {
        var changes: [Change] = []
        var skipped: [String] = []
    }

    /// A file that ColimaBar cannot import at all.
    enum Failure: Error, Equatable {
        case tooLarge
        case notJSON
        case wrongFormat
        case badVersion
        case newerVersion(Int)
        case noSettings

        var message: String {
            switch self {
            case .tooLarge: "The file is too large to be a ColimaBar settings file."
            case .notJSON: "The file is not valid JSON."
            case .wrongFormat: "The file is not a ColimaBar settings file."
            case .badVersion: "The file has no valid version number."
            case .newerVersion(let v):
                "The file has version \(v). This ColimaBar reads version \(SettingsTransfer.version) and older. Update ColimaBar, then try again."
            case .noSettings: "The file has no settings."
            }
        }
    }

    // MARK: - Export

    /// The JSON file for `values`. Keys are sorted, so the same settings
    /// always give the same file.
    static func encode(_ values: Snapshot, appVersion: String) throws -> Data {
        var settings: [String: Any] = [:]
        for (k, v) in values { settings[k.rawValue] = v.json }
        let root: [String: Any] = [
            "format": format, "version": version, "app": appVersion, "settings": settings,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Import

    /// Reads a settings file. It throws for a file that it cannot use at
    /// all. A value of the wrong type or out of range is left out, with a
    /// note in `skipped`. Unknown keys are ignored.
    static func decode(_ data: Data) throws(Failure) -> (values: Snapshot, skipped: [String]) {
        guard data.count <= maxBytes else { throw .tooLarge }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw .notJSON }
        guard let root = obj as? [String: Any], root["format"] as? String == format else { throw .wrongFormat }
        guard let n = root["version"] as? NSNumber, !isBool(n), let v = Int(exactly: n.doubleValue), v >= 1 else {
            throw .badVersion
        }
        if v > version { throw .newerVersion(v) }
        guard let settings = root["settings"] as? [String: Any] else { throw .noSettings }

        var values: Snapshot = [:]
        var skipped: [String] = []
        for s in Setting.allCases {
            guard let raw = settings[s.rawValue] else { continue }
            if let value = validate(raw, for: s) {
                values[s] = value
            } else {
                skipped.append("\(s.title): \(reason(for: s))")
            }
        }
        return (values, skipped)
    }

    /// The changes that importing `data` makes to `current`. A value that is
    /// already set is not a change. A profile that is not in `profiles` is
    /// skipped: switching to it would create a new VM.
    static func plan(_ data: Data, current: Snapshot, profiles: Set<String>) throws(Failure) -> Plan {
        let (values, skipped) = try decode(data)
        var plan = Plan(skipped: skipped)
        for s in Setting.allCases {
            guard let to = values[s], to != current[s] else { continue }
            if s == .profile, case .string(let name) = to, !profiles.contains(name) {
                plan.skipped.append(
                    "Profile: \(name) does not exist on this Mac. To create it, use New Profile… in the profile menu.")
                continue
            }
            plan.changes.append(Change(setting: s, from: current[s], to: to))
        }
        return plan
    }

    /// The value if it has the right type and range for `s`, else nil.
    static func validate(_ raw: Any, for s: Setting) -> Value? {
        switch s {
        case .autoStopMinutes:
            guard let n = raw as? NSNumber, !isBool(n), let m = Int(exactly: n.doubleValue),
                IdleMinutes.range.contains(m)
            else { return nil }
            return .int(m)
        case .profile:
            guard let name = raw as? String, ProfileName.isValid(name) else { return nil }
            return .string(name)
        default:
            guard let n = raw as? NSNumber, isBool(n) else { return nil }
            return .bool(n.boolValue)
        }
    }

    private static func reason(for s: Setting) -> String {
        switch s {
        case .autoStopMinutes:
            "the value must be a whole number from \(IdleMinutes.range.lowerBound) to \(IdleMinutes.range.upperBound)."
        case .profile: "the value is not a valid profile name."
        default: "the value must be true or false."
        }
    }

    /// JSONSerialization gives NSNumber for both true and 1. Only a JSON
    /// true or false is a CFBoolean.
    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}
