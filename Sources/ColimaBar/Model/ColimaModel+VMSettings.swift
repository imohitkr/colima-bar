import CryptoKit
import Foundation

/// What `applyVMSettings` did, so the page knows if it must show the file again.
enum VMApplyOutcome: Equatable, Sendable {
    /// ColimaBar did nothing: a guard stopped it, or the change had a problem.
    case skipped
    /// colima.yaml already had the new values.
    case alreadyThere
    /// colima.yaml changed outside ColimaBar after the page read it.
    case changedOutside
    /// The script ran and succeeded.
    case applied
    /// The script ran and did not succeed, or the user cancelled.
    case failed

    /// The page must fill its fields again from colima.yaml.
    var reloadsForm: Bool { self == .alreadyThere || self == .changedOutside || self == .applied }
}

/// The advanced VM settings (`VMConfigView`). ColimaBar edits the text of
/// colima.yaml with `ColimaYAML`, stages the new file, and lets
/// `colima-ctl.sh vm-config` put it in place. The script owns the lock, the
/// dialog, the backup and the restart.
extension ColimaModel {
    /// True if ColimaBar may start an apply. The old copy quits at once after
    /// the swap of an update. A debug run changes nothing. A busy profile has
    /// an action that holds the lock.
    nonisolated static func mayApplyVMSettings(
        updateRestarting: Bool, isDebug: Bool, changeIsEmpty: Bool, busy: Bool
    ) -> Bool {
        !updateRestarting && !isDebug && !changeIsEmpty && !busy
    }

    /// Writes the change to the colima.yaml of a profile. A running VM
    /// restarts after a dialog. A stopped VM only gets the new file, and
    /// stays stopped. `baselineSHA` is the SHA-256 of the colima.yaml that
    /// the change comes from. If the file is different now, nothing changes.
    /// Another module can call it with a small change, for example
    /// `VMSettingsChange(dnsServers: ["1.1.1.1"])`.
    @discardableResult
    func applyVMSettings(
        _ change: VMSettingsChange, profile p: String, baselineSHA: String? = nil
    ) async -> VMApplyOutcome {
        guard
            Self.mayApplyVMSettings(
                updateRestarting: updateRestarting, isDebug: isDebug, changeIsEmpty: change.isEmpty,
                busy: busyMarker(of: p) != nil)
        else {
            log.notice("VM settings of \(p, privacy: .public): no apply (debug run, busy profile, update or no change)")
            return .skipped
        }
        let staged: (path: String, sha: String)?
        do {
            staged = try Self.stageVMSettings(
                change, configPath: Paths.config(p), stagedPath: Paths.stagedConfig(p), baselineSHA: baselineSHA)
        } catch VMSettingsFailure.changedOutside {
            log.notice("VM settings of \(p, privacy: .public): colima.yaml changed outside ColimaBar")
            notify(VMSettingsFailure.changedOutside.localizedDescription)
            if p == profile { reloadConfig() }
            return .changedOutside
        } catch {
            log.error(
                "VM settings of \(p, privacy: .public) not staged: \(error.localizedDescription, privacy: .public)")
            notify("Couldn't save the VM settings of profile '\(p)': \(error.localizedDescription)")
            return .skipped
        }
        guard let staged else {
            log.notice("VM settings of \(p, privacy: .public): colima.yaml has these values already")
            if p == profile { reloadConfig() }
            return .alreadyThere
        }
        let running = isRunning(profile: p)
        if CtlAction.vmConfig.showsDialog(running: running) { dismissPopover() }
        let label = markBusy(.vmConfig, p, running: running)
        let ok = await execute(
            .vmConfig, [staged.path, staged.sha], profile: p, label: label, expectRunning: running)
        // The Doctor report no longer matches the VM. The next run checks again.
        if ok { publishDoctor(report: nil) }
        if p == profile { reloadConfig() }
        return ok ? .applied : .failed
    }

    /// The SHA-256 of the bytes of a file, as hex.
    nonisolated static func configSHA(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The new text of colima.yaml, written to the staged file. Returns the
    /// path and the SHA-256 of the colima.yaml that the new text comes from,
    /// or nil if the file already has the new values. If `baselineSHA` is
    /// set and the file is different, it throws `VMSettingsFailure.changedOutside`.
    nonisolated static func stageVMSettings(
        _ change: VMSettingsChange, configPath: String, stagedPath: String, baselineSHA: String? = nil
    ) throws -> (path: String, sha: String)? {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let sha = configSHA(data)
        if let baselineSHA, baselineSHA != sha { throw VMSettingsFailure.changedOutside }
        guard let text = String(data: data, encoding: .utf8) else { throw VMSettingsFailure.notText }
        var context = VMSettingsCheck.Context()
        context.current = VMSettings.read(text)
        let problems = VMSettingsCheck.problems(change, context: context)
        if !problems.isEmpty { throw VMSettingsFailure.problems(problems) }
        let new = try ColimaYAML.apply(change, to: text)
        if new == text { return nil }
        try FileManager.default.createDirectory(
            atPath: (stagedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try writeStaged(Data(new.utf8), to: stagedPath)
        return (stagedPath, sha)
    }

    /// Writes the staged file. A file or link from an earlier run must not
    /// stay in the way. The file is new, has mode 0600 from the start and is
    /// not opened through a link. A failure gives the path and the reason.
    nonisolated private static func writeStaged(_ data: Data, to path: String) throws {
        func fail() -> VMSettingsFailure { .notWritten(path: path, reason: String(cString: strerror(errno))) }
        if unlink(path) != 0, errno != ENOENT { throw fail() }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw fail() }
        defer { Darwin.close(fd) }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw fail() }
                offset += n
            }
        }
    }
}
