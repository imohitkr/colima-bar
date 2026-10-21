import SwiftUI

/// The Cleanup page. It replaces the tabs and the stopped screen between the
/// header and the hint bar, so the popover keeps its fixed size. It lists the
/// largest items of Docker and of the VM, and removes them one by one.
struct CleanupView: View {
    let model: ColimaModel
    @Bindable var ui: ViewState

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    diskImageSection
                    if !model.hasDockerSocket {
                        EmptyStateText(text: "This profile does not use the docker runtime.")
                    } else if model.state != .running && model.cleanup.isEmpty {
                        EmptyStateText(text: "Start the VM to see the images, volumes, containers and logs.")
                    } else {
                        dockerSections
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            Divider()
            bottomBar
        }
        .onAppear { model.cleanupOnScreen = true }
        .onDisappear { model.cleanupOnScreen = false }
        .task(id: "\(model.profile)-\(model.state == .running)") {
            await model.refreshLogSizes()
            await model.refreshDiskImage()
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Cleanup · profile \(model.profile)").font(.headline)
                Spacer()
                if model.logSizesChecking { ProgressView().controlSize(.small) }
                Button("Refresh") {
                    Task {
                        model.requestDF(urgent: true)
                        await model.refreshLogSizes(force: true)
                        await model.refreshDiskImage()
                    }
                }
                .hint(Help.cleanupRefresh)
                Button("Done") { ui.showCleanup = false }
                    .hint(Help.cleanupDone)
            }
            if !model.cleanup.isEmpty {
                Text("\(ByteFormat.bytes(model.cleanup.reclaimable)) reclaimable in Docker")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var bottomBar: some View {
        let last = model.pruneLastRun[model.profile]
        let text: String
        if model.scheduledPrune {
            text =
                "Weekly cleanup: on · "
                + (last.map { "last run \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "not run yet.")
        } else {
            text = "Weekly cleanup: off. Turn it on in the System tab."
        }
        return HStack {
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .hint(Help.scheduledPrune)
    }

    // MARK: - Disk image

    private var diskImageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Disk image on the Mac", hint: Help.cleanupDiskImage) { EmptyView() }
            HStack(spacing: 8) {
                if let d = model.diskImage {
                    Text(
                        "\(ByteFormat.bytes(Double(d.allocated))) used · \(ByteFormat.bytes(Double(d.apparent))) maximum"
                    )
                    .font(.system(size: 11).monospacedDigit())
                } else {
                    Text("ColimaBar could not find the disk image.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(model.isTrimming ? "Returning…" : "Return Free Space") { model.trimDisk() }
                    .controlSize(.small).disabled(!model.canTrim)
                    .hint(model.isDebug ? Help.cleanupDebug : Help.cleanupTrim)
            }
            Text("Removing items frees space in the VM. Return Free Space gives it back to the Mac.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Docker sections

    @ViewBuilder private var dockerSections: some View {
        let report = model.cleanup
        block(
            "Images · \(report.images.count) · \(ByteFormat.bytes(report.images.reclaimable)) reclaimable",
            report.images, empty: "No images.", hint: Help.dfImages,
            button: ("Remove Unused…", Help.pruneImages, { model.run(.prune, "images") }))
        block(
            "Unused volumes · \(report.volumes.count) · \(ByteFormat.bytes(report.volumes.reclaimable))",
            report.volumes, empty: "No unused volumes.", hint: Help.dfVolumes,
            button: ("Remove All…", Help.pruneVolumes, { model.run(.prune, "volumes") }))
        block(
            "Stopped containers · \(report.containers.count) · \(ByteFormat.bytes(report.containers.reclaimable))",
            report.containers, empty: "No stopped containers.", hint: Help.dfContainers, button: nil)
        block(
            "Build cache · \(report.buildCache.count) entries · \(ByteFormat.bytes(report.buildCache.reclaimable)) unused",
            report.buildCache, empty: "No build cache.", hint: Help.cleanupCache,
            button: ("Remove Unused…", Help.pruneCache, { model.run(.prune, "cache") }))
        logSection
    }

    @ViewBuilder private var logSection: some View {
        let logs = model.logItems
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                title: "Container logs · \(ByteFormat.bytes(logs.totalSize))", hint: Help.cleanupLogs
            ) { EmptyView() }
            if let error = model.logSizesError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if model.logSizes == nil {
                if model.logSizesChecking {
                    note("Reading the log sizes…")
                } else if model.state != .running {
                    note("Start the VM to read the log sizes.")
                } else if model.logSizesError == nil {
                    note("The log sizes are not read yet.")
                }
            } else if logs.isEmpty {
                note("No log files.")
            } else {
                rows(logs)
            }
        }
    }

    private func block(
        _ title: String, _ section: CleanupReport.Section, empty: String, hint: String,
        button: (title: String, hint: String, action: () -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title, hint: hint) {
                if let button {
                    Button(button.title, action: button.action)
                        .buttonStyle(.borderless).font(.caption).disabled(model.isDebug)
                        .hint(model.isDebug ? Help.cleanupDebug : button.hint)
                }
            }
            if section.isEmpty {
                note(empty)
            } else {
                rows(section)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
    }

    private func rows(_ section: CleanupReport.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(section.items) { item in
                CleanupRow(item: item, isDebug: model.isDebug) { remove(item) }
            }
            if section.hiddenCount > 0 {
                Text("… \(section.hiddenCount) more · \(ByteFormat.bytes(section.hiddenSize))")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
    }

    private func remove(_ item: CleanupItem) {
        guard let removal = item.removal else { return }
        if item.kind == .log {
            model.truncateLog(item)
        } else {
            model.run(removal.action, args: removal.args)
        }
    }
}
