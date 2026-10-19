import AppKit
import SwiftUI

/// The Inspect page of one container. It replaces the tabs between the
/// header and the hint bar, so the popover keeps its fixed size. The detail
/// lives in `InspectState`, not in the model: environment values never reach
/// the model, the status file or the diagnostics.
struct InspectView: View {
    let model: ColimaModel
    @Bindable var ui: ViewState
    let id: String

    private var state: InspectState { ui.inspect }
    private var detail: ContainerDetail? { state.detail }
    private var gone: Bool { state.gone }

    private static let refreshSeconds = 2

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                content
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .task(id: "\(model.profile)/\(id)") { await refreshLoop() }
    }

    /// Reads the container now and every 2 s, but not while no dashboard is
    /// on screen. It ends when the container is gone.
    private func refreshLoop() async {
        state.reset()
        var digests: [String]?
        while !Task.isCancelled {
            if model.visibleCount > 0 {
                switch await model.inspect(id: id, digests: digests) {
                case .found(let d):
                    digests = d.digests
                    state.recordFound(d)
                case .gone:
                    state.detail = nil
                    state.gone = true
                    return
                case .unavailable:
                    state.recordUnavailable()
                case .failed(let reason):
                    if state.recordFailure(reason) { model.logInspectFailure(reason) }
                }
            }
            try? await Task.sleep(for: .seconds(Self.refreshSeconds))
        }
    }

    // MARK: - Top bar

    private var name: String {
        detail?.name ?? model.container(withID: id)?.name ?? String(id.prefix(12))
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if let detail { Circle().fill(dot(detail)).frame(width: 7, height: 7) }
            Text("Inspect · \(name)").font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let c = model.container(withID: id), c.state == "running", !gone {
                Button("Debug shell") { model.debugShell(c) }
                    .disabled(model.isDebug)
                    .hint(model.isDebug ? Help.debugShellDebug : Help.debugShell)
            }
            if !gone { Button("Logs") { model.openLogs(id: id, name: name) }.hint(Help.logs) }
            Button("Done") { ui.inspectID = nil }
                .keyboardShortcut(.cancelAction)
                .hint(Help.inspectDone)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func dot(_ d: ContainerDetail) -> Color {
        if d.health?.status == "unhealthy" { return .red }
        switch d.status {
        case "running": return .green
        case "paused", "restarting": return .orange
        default: return .secondary.opacity(0.6)
        }
    }

    // MARK: - Sections

    @ViewBuilder private var content: some View {
        if gone {
            Text("This container no longer exists.").font(.caption).foregroundStyle(.secondary)
        } else if detail == nil, let problem = state.problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        } else if let d = detail {
            VStack(alignment: .leading, spacing: 8) {
                if let problem = state.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                } else if state.isStale {
                    Text("The VM does not answer now. This is the last data that ColimaBar read.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                imageSection(d)
                stateSection(d)
                if let h = d.health { healthSection(h) }
                commandSection(d)
                environmentSection(d)
                labelsSection(d)
                networksSection(d)
                mountsSection(d)
                portsSection(d)
                resourcesSection(d)
            }
        } else {
            Text("Reading the container…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func imageSection(_ d: ContainerDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Image")
            row("Image", d.imageRef)
            if let digest = d.digest {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label("Digest")
                    Text(String(digest.prefix("sha256:".count + 12)) + "…").textSelection(.enabled)
                    IconButton("doc.on.doc", Help.copyDigest) { Pasteboard.copy(digest) }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
            }
            row("Image ID", String(d.imageID.replacingOccurrences(of: "sha256:", with: "").prefix(12)))
        }
    }

    private func stateSection(_ d: ContainerDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "State")
            row("Status", d.status == "running" ? "running" : "\(d.status) (exit code \(d.exitCode))")
            if d.oomKilled { row("Killed", "Out of memory", color: .red) }
            if !d.error.isEmpty { row("Error", d.error, color: .red) }
            row("Created", when(d.created))
            row("Started", when(d.started))
            if d.status != "running" { row("Finished", when(d.finished)) }
            row("Restart policy", d.restartPolicy)
            row("Restarts", d.restartCount == 1 ? "Restarted 1 time" : "Restarted \(d.restartCount) times")
        }
    }

    private func healthSection(_ h: ContainerDetail.Health) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Health")
            row("Status", h.status, color: h.status == "healthy" ? .green : h.status == "unhealthy" ? .red : .orange)
            row("Failing streak", String(h.failingStreak))
            ForEach(Array(h.log.enumerated()), id: \.offset) { _, line in
                row(
                    line.date.map { $0.formatted(date: .omitted, time: .standard) } ?? "–",
                    "exit \(line.exitCode)\(line.output.isEmpty ? "" : " · \(line.output)")")
            }
        }
    }

    private func commandSection(_ d: ContainerDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Command")
            if !d.entrypoint.isEmpty { row("Entrypoint", EnvMask.maskArgs(d.entrypoint).joined(separator: " ")) }
            if !d.command.isEmpty { row("Command", EnvMask.maskArgs(d.command).joined(separator: " ")) }
            if !d.workingDir.isEmpty { row("Working dir", d.workingDir) }
            row("User", d.user.isEmpty ? "root" : d.user)
        }
    }

    private func environmentSection(_ d: ContainerDetail) -> some View {
        let hiddenCount = d.env.filter(\.isSecret).count
        return VStack(alignment: .leading, spacing: 3) {
            SectionHeader(
                title: hiddenCount == 0 ? "Environment" : "Environment · \(hiddenCount) hidden", hint: Help.envHidden,
                trailing: { EmptyView() })
            if d.env.isEmpty { none }
            ForEach(Array(d.env.enumerated()), id: \.offset) { _, e in
                InspectEnvRow(
                    key: e.key, value: e.value, isSecret: e.isSecret, isRevealed: state.isRevealed("env:\(e.key)"),
                    toggle: { state.toggle("env:\(e.key)") })
            }
        }
    }

    private func labelsSection(_ d: ContainerDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Labels")
            if d.labels.isEmpty { none }
            ForEach(d.labels, id: \.key) { l in
                InspectEnvRow(
                    key: l.key, value: l.value, isSecret: l.isSecret, keyColor: l.isCompose ? .blue : .secondary,
                    isRevealed: state.isRevealed("label:\(l.key)"), toggle: { state.toggle("label:\(l.key)") })
            }
        }
    }

    private func networksSection(_ d: ContainerDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Networks")
            if d.networks.isEmpty { none }
            ForEach(d.networks, id: \.name) { n in
                row(n.name, [n.ipv4, n.ipv6].filter { !$0.isEmpty }.joined(separator: " · "))
                if !n.aliases.isEmpty { row("", "Aliases: " + n.aliases.joined(separator: ", ")) }
            }
        }
    }

    private func mountsSection(_ d: ContainerDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Mounts")
            if d.mounts.isEmpty { none }
            ForEach(Array(d.mounts.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label(m.readWrite ? "\(m.type) · rw" : "\(m.type) · ro")
                    Text("\(m.source) → \(m.destination)").textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    mountAction(m)
                }
                .font(.system(size: 11))
            }
        }
    }

    /// A bind mount that comes from the Mac opens in Finder. A bind mount
    /// that does not is a path in the VM only.
    @ViewBuilder private func mountAction(_ m: ContainerDetail.Mount) -> some View {
        if m.type == "bind" {
            if let path = macFolder(m), FileManager.default.fileExists(atPath: path) {
                IconButton("folder", Help.openFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            } else {
                Text("VM only").font(.system(size: 10)).foregroundStyle(.tertiary).hint(Help.vmOnlyPath)
            }
        }
    }

    private func macFolder(_ m: ContainerDetail.Mount) -> String? {
        guard let read = model.vmSettings else { return nil }
        return MountPathMap.macPath(
            vmPath: m.source, mounts: read.mounts, defaultHome: read.mountsDefaultHome, home: NSHomeDirectory())
    }

    private func portsSection(_ d: ContainerDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Ports")
            if d.ports.isEmpty { none }
            ForEach(Array(d.ports.enumerated()), id: \.offset) { _, p in
                HStack(spacing: 8) {
                    // verbatim: a localized Text would show 18080 as "18.080".
                    Text(
                        verbatim:
                            "\(p.hostPort) → \(p.containerPort)/\(p.proto)\(p.hostIP.isEmpty ? "" : " (\(p.hostIP))")"
                    )
                    .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if let url = PortLink.url(
                        hostPort: p.hostPort, containerPort: p.containerPort, proto: p.proto, hostIP: p.hostIP)
                    {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderless).hint(Help.openBrowser)
                    } else {
                        // A String title, not a localized key: no "18.080".
                        Button("Copy localhost:" + String(p.hostPort)) { Pasteboard.copy("localhost:\(p.hostPort)") }
                            .buttonStyle(.borderless).hint(Help.copyPort)
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private func resourcesSection(_ d: ContainerDetail) -> some View {
        let noLimit = "No limit"
        return VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "Resources")
            row("Memory limit", d.memoryLimit > 0 ? ByteFormat.bytes(Double(d.memoryLimit)) : noLimit)
            row("Reservation", d.memoryReservation > 0 ? ByteFormat.bytes(Double(d.memoryReservation)) : noLimit)
            row("CPUs", d.cpus > 0 ? String(format: "%g", d.cpus) : noLimit)
            row("CPU shares", d.cpuShares > 0 ? String(d.cpuShares) : noLimit)
            row("Processes", d.pidsLimit > 0 ? String(d.pidsLimit) : noLimit)
            row("Privileged", d.privileged ? "yes" : "no", color: d.privileged ? .orange : nil)
        }
    }

    // MARK: - Helpers

    private var none: some View {
        Text("None").font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
    }

    private func row(_ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(title)
            Text(value).foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
    }

    /// "3 hours ago · 19 Oct 2026 at 10:00:00", or "never" for a zero date.
    private func when(_ date: Date?) -> String {
        guard let date else { return "never" }
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "\(relative) · \(date.formatted(date: .abbreviated, time: .standard))"
    }
}
