import Foundation
import os

/// The checks of a downloaded update. Each step stops the update before
/// anything in the Applications folder changes.
enum UpdateVerifier {
    static let bundleID = "com.imohitkr.ColimaBar"
    static let appName = "ColimaBar.app"
    /// The `colimabar` command in the bundle. A copy without it would leave
    /// the links of the user and of Homebrew broken.
    static let commandPath = "Contents/Resources/bin/colimabar"
    private static let log = Logger(category: "update")

    /// Step 1: the byte count and the SHA-256 digest equal the API values.
    static func checkDownload(bytes: Int, sha256: String, asset: ReleaseInfo.Asset) throws {
        guard bytes == asset.size else { throw UpdateError.sizeMismatch }
        guard ReleaseDigest.matches(sha256, asset.sha256) else { throw UpdateError.digestMismatch }
    }

    /// Step 3: unpacks `zip` into `folder` with `ditto`. The folder must be
    /// empty. The zip must hold exactly one entry, `ColimaBar.app`, with at
    /// most `UpdatePolicy.maxUnpackedBytes` of files.
    static func unpack(zip: URL, into folder: URL) async throws -> URL {
        let r = await Shell.run(
            ["/usr/bin/ditto", "-x", "-k", zip.path, folder.path], timeout: 60, includeStderr: true,
            cancellable: true)
        guard r.ok else {
            log.error("ditto failed with status \(r.status): \(r.out.prefix(1000), privacy: .public)")
            throw UpdateError.unpackFailed("ditto failed")
        }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        guard entries == [appName] else { throw UpdateError.unpackFailed("the zip must hold only \(appName)") }
        let app = folder.appendingPathComponent(appName)
        var isDir: ObjCBool = false
        let attrs = try? fm.attributesOfItem(atPath: app.path)
        guard fm.fileExists(atPath: app.path, isDirectory: &isDir), isDir.boolValue,
            (attrs?[.type] as? FileAttributeType) == .typeDirectory
        else { throw UpdateError.unpackFailed("\(appName) is not a folder") }
        guard unpackedSize(of: app) <= UpdatePolicy.maxUnpackedBytes else {
            throw UpdateError.unpackFailed("the unpacked app is too large")
        }
        return app
    }

    /// The total size of the regular files in `folder`. A folder that cannot
    /// be read counts as too large.
    static func unpackedSize(of folder: URL) -> Int {
        guard FileManager.default.fileExists(atPath: folder.path),
            let e = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        else { return Int.max }
        var total = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else { return Int.max }
            if v.isRegularFile == true { total += v.fileSize ?? 0 }
        }
        return total
    }

    /// The arguments of `codesign` for step 4. The `=` at the start of the
    /// requirement makes `codesign` read it as text.
    static func codesignArguments(_ app: String) -> [String] {
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=identifier \"\(bundleID)\"", app]
    }

    /// Step 4: the signature is valid for the whole bundle and the code
    /// identifier is ColimaBar's. An ad-hoc signature shows integrity only.
    static func checkSignature(_ app: URL) async throws {
        let r = await Shell.run(codesignArguments(app.path), timeout: 60, includeStderr: true, cancellable: true)
        guard r.ok else {
            log.error("codesign failed with status \(r.status): \(r.out.prefix(1000), privacy: .public)")
            throw UpdateError.signatureInvalid
        }
    }

    /// Step 5: the problem with the Info.plist of the unpacked app, or nil.
    static func plistProblem(_ plist: [String: Any]?, tag: String, running: String) -> String? {
        guard let plist else { return "the Info.plist cannot be read" }
        guard plist["CFBundleIdentifier"] as? String == bundleID else {
            return "the bundle identifier is not \(bundleID)"
        }
        guard plist["CFBundleExecutable"] as? String == "ColimaBar" else { return "the executable is not ColimaBar" }
        let version = plist["CFBundleShortVersionString"] as? String
        guard let version, version == Version.strip(tag) else { return "the version is not \(Version.strip(tag))" }
        guard Version.isNewer(version, than: running) else { return "the version is not newer than \(running)" }
        return nil
    }

    /// Steps 4 to 6 for an unpacked app: the signature, the plist, the
    /// bundled files (the binary, the script and the command) and the quarantine flag. It removes the quarantine
    /// flag from the unpacked copy only (URLSession sets none).
    static func verifyBundle(_ app: URL, tag: String, running: String) async throws {
        try await checkSignature(app)
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if let why = plistProblem(plist, tag: tag, running: running) { throw UpdateError.bundleInvalid(why) }
        guard
            FileManager.default.isExecutableFile(
                atPath: app.appendingPathComponent("Contents/MacOS/ColimaBar").path),
            FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/colima-ctl.sh").path),
            FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(commandPath).path)
        else { throw UpdateError.bundleInvalid("a bundled file is missing") }
        try await clearQuarantine(app)
    }

    /// True if an `xattr -r` listing still has the quarantine flag.
    static func hasQuarantine(listing: String) -> Bool {
        listing.contains("com.apple.quarantine")
    }

    /// Removes the quarantine flag from `app`, then reads the flags again.
    /// The update stops if the flag is still there: the swap must not put a
    /// flagged bundle in place, and the log has the output.
    static func clearQuarantine(_ app: URL) async throws {
        let rm = await Shell.run(
            ["/usr/bin/xattr", "-dr", "com.apple.quarantine", app.path], timeout: 30, includeStderr: true,
            cancellable: true)
        if !rm.ok { log.error("xattr -dr failed with status \(rm.status): \(rm.out.prefix(1000), privacy: .public)") }
        let list = await Shell.run(
            ["/usr/bin/xattr", "-r", app.path], timeout: 30, includeStderr: true, cancellable: true)
        guard list.ok, !hasQuarantine(listing: list.out) else {
            log.error("quarantine check failed with status \(list.status): \(list.out.prefix(1000), privacy: .public)")
            throw UpdateError.other("ColimaBar could not remove the quarantine flag from the download")
        }
    }

    /// All steps for a finished download in `folder`. Returns the unpacked
    /// app and the result of the attestation check.
    /// `allowAttestationSkip` is true only if the confirmation dialog said
    /// that the attestation check would not run (see `AttestationCheck.verify`).
    static func verify(
        download: UpdateDownload.Output, asset: ReleaseInfo.Asset, tag: String, running: String, folder: URL,
        allowAttestationSkip: Bool
    ) async throws -> (app: URL, attestation: AttestationCheck.Outcome) {
        try checkDownload(bytes: download.bytes, sha256: download.sha256, asset: asset)
        let attestation = try await AttestationCheck.verify(
            zip: download.file, tag: tag, allowSkip: allowAttestationSkip)
        try Task.checkCancellation()
        let unpacked = folder.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(
            at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let app = try await unpack(zip: download.file, into: unpacked)
        try await verifyBundle(app, tag: tag, running: running)
        return (app, attestation)
    }
}
