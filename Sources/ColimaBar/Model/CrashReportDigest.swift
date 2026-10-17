import Foundation

/// A short version of a macOS crash report (`.ips`) of ColimaBar. It keeps a
/// fixed list of keys and drops the rest (ids of the Mac, the boot session,
/// the user id, the code signing data). Pure: the caller reads the file.
enum CrashReportDigest {
    /// The app name that the header must have. A report of another app gives nil.
    static let appName = "ColimaBar"
    /// The size limit of one digest.
    static let maxBytes = 128 * 1024
    /// The most reports that the file names.
    static let maxNames = 10
    /// The reports of the last 30 days count.
    static let window: TimeInterval = 30 * 24 * 3600

    private static let headerKeys = ["app_name", "app_version", "build_version", "os_version", "timestamp", "bug_type"]
    private static let bodyKeys = [
        "captureTime", "osVersion", "modelCode", "cpuType", "procName", "procPath", "exception", "termination",
        "asi", "faultingThread", "threads", "lastExceptionBacktrace", "usedImages",
    ]

    /// The digest of the text of one report, or nil if it is not a report of
    /// ColimaBar or is not valid. A report is a header line of JSON, then the
    /// body of JSON.
    static func reduce(_ text: String) -> String? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let header = object(parts[0]), let body = object(parts[1]),
            header["app_name"] as? String == appName
        else { return nil }
        var lines: [String] = []
        for k in headerKeys { if let v = header[k] { lines.append("\(k): \(render(v))") } }
        for k in bodyKeys { if let v = body[k] { lines.append("\(k): \(render(v))") } }
        return DiagnosticsBundle.head(lines.joined(separator: "\n"), bytes: maxBytes)
    }

    private static func object<S: StringProtocol>(_ text: S) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// A value on one line: plain for a string or number, else compact JSON.
    private static func render(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
            let s = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return s
    }

    /// The names of the reports to list: the reports of ColimaBar from the
    /// last 30 days, newest first, at most 10. The date is in the name
    /// (`ColimaBar-2026-03-01-120000.ips`, in local time).
    static func pick(names: [String], now: Date, calendar: Calendar = .current) -> [String] {
        let dated = names.compactMap { n -> (name: String, date: Date)? in
            guard n.hasSuffix(".ips"), let d = date(of: n, calendar: calendar) else { return nil }
            return (n, d)
        }
        return dated.filter { now.timeIntervalSince($0.date) <= window }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name > $1.name }
            .prefix(maxNames).map(\.name)
    }

    private static func date(of name: String, calendar: Calendar) -> Date? {
        guard name.hasPrefix(appName + "-"), name.count >= appName.count + 18 else { return nil }
        let rest = Array(name.dropFirst(appName.count + 1).prefix(17))
        // YYYY-MM-DD-HHMMSS
        guard rest.count == 17, rest[4] == "-", rest[7] == "-", rest[10] == "-" else { return nil }
        func n(_ r: Range<Int>) -> Int? { Int(String(rest[r])) }
        guard let y = n(0..<4), let mo = n(5..<7), let d = n(8..<10), let h = n(11..<13), let mi = n(13..<15),
            let s = n(15..<17)
        else { return nil }
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
    }
}
