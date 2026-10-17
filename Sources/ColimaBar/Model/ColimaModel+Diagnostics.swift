import AppKit
import Foundation
import os

private let diagnosticsLog = Logger(category: "diagnostics")

/// The diagnostics file: one text file that the user can read, edit and
/// attach to a bug report. See `DiagnosticsBundle` for the file and
/// `DiagnosticsProbe` for the reads. It reads only. It never starts the VM.
extension ColimaModel {
    /// The text of the file, and what the issue link needs.
    struct Collected: Sendable {
        let text: String
        let fields: IssueLink.Fields
        let redactor: Redactor
    }

    /// Why a save did not finish.
    enum SaveError: LocalizedError {
        case busy
        var errorDescription: String? { "A diagnostics file is already being saved." }
    }

    /// Collects the file, writes it to `url` with the mode 0600, and shows it
    /// in Finder. With `report` it also opens the bug report form. A debug run
    /// opens nothing. Returns the error if the file was not written, else
    /// nil. One run at a time. `stateKnown` is false if the last `colima
    /// list` gave no list (a debug run asks first).
    @discardableResult
    func saveDiagnostics(to url: URL, report: Bool = false, stateKnown: Bool = true) async -> Error? {
        guard !isSavingDiagnostics else { return SaveError.busy }
        setSavingDiagnostics(true)
        defer { setSavingDiagnostics(false) }
        let collected = await collectDiagnostics(stateKnown: stateKnown)
        do {
            try DiagnosticsProbe.write(collected.text, to: url)
        } catch {
            diagnosticsLog.error("diagnostics file not written: \(error.localizedDescription, privacy: .public)")
            notify("ColimaBar could not save the diagnostics file: \(error.localizedDescription)")
            return error
        }
        diagnosticsLog.notice("diagnostics file written (\(collected.text.utf8.count) bytes)")
        guard !isDebug else { return nil }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if report {
            let link = IssueLink.url(collected.fields, redactor: collected.redactor)
            if !NSWorkspace.shared.open(link) {
                diagnosticsLog.error("the browser did not open the bug report form")
                notify(
                    "ColimaBar could not open the browser. Open this link to report the issue: \(link.absoluteString)")
            }
        }
        return nil
    }

    /// Reads all parts at once, each with its own limit. The texts that come
    /// from the model are made first, so they all show one profile and one
    /// moment. A profile switch during the run shows in the summary.
    func collectDiagnostics(stateKnown: Bool = true) async -> Collected {
        let started = ContinuousClock.now
        let p = profile
        let gen = generation
        let vmState = stateKnown || state == .notInstalled ? state : .unknown
        let plan = DiagnosticsPart.planned(state: vmState)
        let settings = settingsText()
        let stateBlock = stateText(profile: p, state: vmState)
        let runtime = vm.runtime

        async let names = Deadline.run(
            seconds: 5, fallback: (Redactor(home: Paths.home, userNames: [NSUserName(), NSFullUserName()]), false)
        ) { await DiagnosticsProbe.redactor() }
        async let tools = Deadline.run(seconds: DiagnosticsPart.tools.deadline, fallback: DoctorInputs.Tools?.none) {
            await DoctorProbe.tools()
        }

        let probed = await withTaskGroup(of: DiagnosticsSection.self) { group in
            for (part, skipped) in plan where ![.tools, .settings, .state, .goodStarts].contains(part) {
                if let skipped {
                    group.addTask { DiagnosticsSection(part: part, outcome: .skipped(skipped)) }
                    continue
                }
                group.addTask {
                    let why = "no answer after \(Int(part.deadline)) s"
                    let outcome = await Deadline.run(seconds: part.deadline, fallback: .failed(why)) {
                        part == .doctor
                            ? await self.doctorOutcome(profile: p) : await DiagnosticsProbe.run(part, profile: p)
                    }
                    return DiagnosticsSection(part: part, outcome: outcome)
                }
            }
            var all: [DiagnosticsSection] = []
            for await s in group { all.append(s) }
            return all
        }
        let toolsFound = await tools
        var byPart = Dictionary(uniqueKeysWithValues: probed.map { ($0.part, $0) })
        byPart[.tools] = DiagnosticsSection(
            part: .tools,
            outcome: toolsFound.map { .ok(DiagnosticsProbe.toolsText($0)) } ?? .failed("no answer"))
        byPart[.settings] = DiagnosticsSection(part: .settings, outcome: .ok(settings))
        byPart[.state] = DiagnosticsSection(part: .state, outcome: .ok(stateBlock))
        byPart[.goodStarts] = DiagnosticsSection(
            part: .goodStarts, outcome: .ok(goodStartsText(current: toolsFound?.versions)))
        let sections = plan.compactMap { byPart[$0.part] }

        var notes: [String] = []
        let (hide, namesComplete) = await names
        if !namesComplete { notes.append("Mac names: not all read; check the file before you share it.") }
        if gen != generation || profile != p {
            notes.append(
                "The profile changed during the run (\(p) to \(profile)). The file shows the profile \(p).")
        }
        let seconds = Double((ContinuousClock.now - started).components.seconds)
        let elapsed = max(seconds, 0)
        let isDebugRun = isDebug
        let version = AppDelegate.version
        // The redactor reads up to 2 MB: keep it off the main actor.
        let text = await Task.detached {
            DiagnosticsBundle.render(
                sections: sections, date: Date(), version: version, isDebugRun: isDebugRun,
                elapsed: elapsed, notes: notes, redactor: hide)
        }.value
        let report = doctorReport.flatMap { $0.profile == p ? $0 : nil }
        let fields = IssueLink.fields(
            report: report, versions: toolsFound?.versions ?? ToolVersions(),
            macOS: ToolVersions.macOS(ProcessInfo.processInfo.operatingSystemVersion),
            colimaBar: AppDelegate.version, runtime: runtime, profile: p)
        return Collected(text: text, fields: fields, redactor: hide)
    }

    // MARK: - Parts of the model

    /// The Doctor report of profile `p`. A fresh one is reused. If Doctor
    /// runs, it waits for that run (the deadline ends the wait). Else Doctor
    /// runs now. A report of another profile does not count.
    private func doctorOutcome(profile p: String) async -> DiagnosticsSection.Outcome {
        func report() -> DoctorReport? { doctorReport.flatMap { $0.profile == p ? $0 : nil } }
        if let r = report(), !r.isStale(now: Date()) { return .ok(doctorText(r)) }
        guard profile == p else { return .failed("the profile changed before Doctor ran") }
        if isDoctorRunning {
            while isDoctorRunning, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        } else {
            await runDoctor()
        }
        guard let r = report() else { return .failed("Doctor gave no report") }
        return .ok(doctorText(r))
    }

    private func doctorText(_ r: DoctorReport) -> String {
        let age = max(0, Int(Date().timeIntervalSince(r.date)))
        return r.text(home: Paths.home, version: AppDelegate.version) + "\nThe report is \(age) s old."
    }

    private func settingsText() -> String {
        let snapshot = settingsSnapshot
        var lines = SettingsTransfer.Setting.allCases.compactMap { s in
            snapshot[s].map { "\(s.title): \($0.text(for: s))" }
        }
        lines.append("Colima folder: \(Paths.colimaDir)")
        lines.append("Lima folder: \(Paths.limaDir)")
        lines += DiagnosticsProbe.environmentNames(ProcessInfo.processInfo.environment)
        return lines.joined(separator: "\n")
    }

    private func stateText(profile: String, state: VMState) -> String {
        let running = containers.filter { $0.state == "running" }.count
        let vmState: String
        switch state {
        case .unknown: vmState = "unknown"
        case .running: vmState = "running"
        case .stopped: vmState = "stopped"
        case .notInstalled: vmState = "Colima is not installed"
        }
        let list = profiles.map { "\($0.name) (\($0.status.isEmpty ? "unknown" : $0.status))" }
        var lines = [
            "Profile: \(profile)",
            "VM: \(vmState)",
            "Action in progress: \(busy ?? "none")",
            "The last start failed: \(startFailed ? "yes" : "no")",
            "Auto-stop due: \(autoStopAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "not set")",
            "Containers: \(containers.count) in all, \(running) running",
            "Profiles: \(list.isEmpty ? "none listed" : list.joined(separator: ", "))",
        ]
        if state == .running {
            lines.append(
                "VM size: \(vm.cpus) CPUs, \(vm.memGB) GiB memory, \(vm.diskGB) GiB disk, \(vm.driver), runtime \(vm.runtime), mounts \(vm.mountType)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func goodStartsText(current: ToolVersions?) -> String {
        func show(_ v: ToolVersions) -> String {
            "colima \(v.colima ?? "?"), lima \(v.lima ?? "?"), macOS \(v.macOS ?? "?")"
        }
        let records = goodStarts().records
        var lines = records.keys.sorted().map { "\($0): \(show(records[$0]!))" }
        if lines.isEmpty { lines = ["No good start is recorded."] }
        lines.append("Now: \(current.map(show) ?? "not read")")
        return lines.joined(separator: "\n")
    }
}
