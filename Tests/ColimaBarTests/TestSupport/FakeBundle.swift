import Foundation

@testable import ColimaBar

/// A small app bundle for update tests, in a temporary folder. It is not
/// ColimaBar. The executable is a copy of /usr/bin/true. Never point a test
/// at /Applications or ~/Applications.
enum FakeBundle {
    /// Makes `<folder>/<name>` and, unless `sign` is false, signs it ad-hoc.
    /// `signIdentifier` sets another code identifier than the bundle id.
    @discardableResult
    static func make(
        in folder: String, name: String = "ColimaBar.app", id: String = "com.imohitkr.ColimaBar",
        version: String = "0.9.1", executable: String = "ColimaBar", withScript: Bool = true, sign: Bool = true,
        signIdentifier: String? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        let app = URL(fileURLWithPath: folder).appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(executable))
        if withScript { try Data("#!/bin/sh\n".utf8).write(to: resources.appendingPathComponent("colima-ctl.sh")) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleExecutable": executable,
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign {
            var args = ["/usr/bin/codesign", "--force", "--sign", "-"]
            if let signIdentifier { args += ["--identifier", signIdentifier] }
            let r = await Shell.run(args + [app.path], includeStderr: true)
            if !r.ok { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: r.out]) }
        }
        return app
    }

    /// Zips the given entries of `folder` with ditto, without a parent folder.
    static func zip(_ entries: [String], in folder: String, to zip: String) async throws {
        let staging = "\(folder)/zip-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        for e in entries {
            try FileManager.default.copyItem(atPath: "\(folder)/\(e)", toPath: "\(staging)/\(e)")
        }
        let r = await Shell.run(["/usr/bin/ditto", "-c", "-k", staging, zip], includeStderr: true)
        if !r.ok { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: r.out]) }
    }
}
