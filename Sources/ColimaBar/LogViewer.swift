import AppKit
import Observation
import SwiftUI

struct LogLine: Identifiable, Equatable {
    let id: Int
    let time: String     // HH:mm:ss.SSS, local time
    let text: String
    let stderr: Bool
}

/// Docker multiplexes stdout/stderr of non-TTY containers into frames:
/// [stream(1), 0, 0, 0, size(4, big-endian)] + payload. TTY containers send
/// raw text. Keeps partial lines per stream between reads.
struct LogDemuxer {
    let tty: Bool
    private var buffer = Data()
    private var partial: [Bool: String] = [false: "", true: ""]

    init(tty: Bool) { self.tty = tty }

    /// Returns complete lines as (text, isStderr).
    mutating func feed(_ data: Data) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        if tty {
            split(String(decoding: data, as: UTF8.self), stderr: false, into: &out)
            return out
        }
        buffer.append(data)
        while buffer.count >= 8 {
            let b = buffer.startIndex
            let size = Int(buffer[b + 4]) << 24 | Int(buffer[b + 5]) << 16 | Int(buffer[b + 6]) << 8 | Int(buffer[b + 7])
            guard buffer.count >= 8 + size else { break }
            let payload = buffer[(b + 8)..<(b + 8 + size)]
            let isErr = buffer[b] == 2
            split(String(decoding: payload, as: UTF8.self), stderr: isErr, into: &out)
            buffer.removeSubrange(b..<(b + 8 + size))
        }
        return out
    }

    private mutating func split(_ s: String, stderr: Bool, into out: inout [(String, Bool)]) {
        var text = (partial[stderr] ?? "") + s
        var parts = text.components(separatedBy: "\n")
        text = parts.removeLast()
        partial[stderr] = text
        for p in parts { out.append((p.hasSuffix("\r") ? String(p.dropLast()) : p, stderr)) }
    }
}

/// Live log state for one container. Bytes arrive on a background thread,
/// are batched, and published to the UI ten times a second at most.
@MainActor @Observable
final class LogStore {
    let containerID: String
    let name: String
    var lines: [LogLine] = []
    var search = ""
    var follow = true
    var showTime = true
    var wrap = true
    var stderrOnly = false
    var status = "Connecting…"

    @ObservationIgnored private let api: DockerAPI
    @ObservationIgnored private var handle: StreamHandle?
    @ObservationIgnored private var pending: [LogLine] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var lastTimestamp: String?
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var closed = false
    private let maxLines = 20_000

    init(api: DockerAPI, containerID: String, name: String) {
        self.api = api
        self.containerID = containerID
        self.name = name
    }

    var visible: [LogLine] {
        let q = search.lowercased()
        return lines.filter { (!stderrOnly || $0.stderr) && (q.isEmpty || $0.text.lowercased().contains(q)) }
    }

    func start() {
        closed = false
        Task { await connect(tail: 1000) }
    }

    func stop() {
        closed = true
        handle?.cancel()
        handle = nil
    }

    func clear() { lines.removeAll() }

    var allText: String {
        visible.map { showTime ? "\($0.time)  \($0.text)" : $0.text }.joined(separator: "\n")
    }

    private func connect(tail: Int) async {
        guard !closed else { return }
        var tty = false
        if let r = await api.get("/containers/\(containerID)/json"), r.ok,
           let j = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
           let config = j["Config"] as? [String: Any] {
            tty = config["Tty"] as? Bool ?? false
        } else {
            status = "This container has been removed, so its logs are gone."
            return
        }
        var q = "follow=1&stdout=1&stderr=1&timestamps=1&tail=\(tail)"
        if let since = lastTimestamp { q += "&since=\(DockerAPI.q(since))" }
        status = "Live"
        let box = DemuxBox(LogDemuxer(tty: tty))
        handle = api.streamRaw("/containers/\(containerID)/logs?\(q)", onData: { [weak self] data in
            let lines = box.feed(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor in self?.receive(lines) }
        }, onEnd: { [weak self] in
            Task { @MainActor in self?.ended() }
        })
    }

    private func receive(_ raw: [(String, Bool)]) {
        for (line, isErr) in raw {
            // "2026-10-02T14:03:11.123456789Z message"
            var text = line
            var time = ""
            if let sp = line.firstIndex(of: " "), line.first?.isNumber == true {
                let ts = String(line[..<sp])
                lastTimestamp = ts
                time = Self.clock(ts)
                text = String(line[line.index(after: sp)...])
            }
            pending.append(LogLine(id: nextID, time: time, text: text, stderr: isErr))
            nextID += 1
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            flushScheduled = false
            lines.append(contentsOf: pending)
            pending.removeAll()
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }

    /// Stream ends when the container stops or restarts: keep the window and
    /// reconnect from the last timestamp once it's back.
    private func ended() {
        guard !closed else { return }
        status = "Container stopped. Waiting for it to start…"
        Task {
            try? await Task.sleep(for: .seconds(2))
            await connect(tail: 0)
        }
    }

    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func clock(_ ts: String) -> String {
        // Trim nanoseconds to milliseconds so ISO8601DateFormatter can parse it.
        var s = ts
        if let dot = s.firstIndex(of: "."), let z = s.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), z > dot {
            let frac = s[s.index(after: dot)..<z]
            s = String(s[...dot]) + String(frac.prefix(3)) + String(s[z...])
        }
        return parser.date(from: s).map { display.string(from: $0) } ?? ""
    }
}

/// Thread-confined demuxer state for the background reader.
private final class DemuxBox: @unchecked Sendable {
    private var demux: LogDemuxer
    init(_ d: LogDemuxer) { demux = d }
    func feed(_ data: Data) -> [(String, Bool)] { demux.feed(data) }
}

struct LogView: View {
    @Bindable var store: LogStore
    var openInTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter lines", text: $store.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .hint("Show only lines containing this text (case-insensitive).")
                Toggle("Follow", isOn: $store.follow).hint("Keep scrolled to the newest line.")
                Toggle("Time", isOn: $store.showTime).hint("Show each line's timestamp (local time).")
                Toggle("Wrap", isOn: $store.wrap).hint("Wrap long lines instead of scrolling sideways.")
                Toggle("stderr", isOn: $store.stderrOnly).hint("Show only lines the container wrote to stderr.")
                Spacer()
                IconButton("doc.on.doc", "Copy the visible lines.") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.allText, forType: .string)
                }
                IconButton("trash", "Clear the window. New lines keep arriving.") { store.clear() }
                IconButton("terminal", "Follow these logs in iTerm instead.") { openInTerminal() }
            }
            .toggleStyle(.checkbox).controlSize(.small)
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(store.wrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.visible) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if store.showTime {
                                    Text(line.time).foregroundStyle(.tertiary)
                                }
                                Text(line.text)
                                    .foregroundStyle(line.stderr ? Color.red.opacity(0.9) : .primary)
                                    .fixedSize(horizontal: !store.wrap, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.lines.last?.id) {
                    if store.follow, let last = store.visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Circle().fill(store.status == "Live" ? Color.green : .orange).frame(width: 6, height: 6)
                Text(store.status)
                Spacer()
                Text("\(store.visible.count) of \(store.lines.count) lines").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            HintBar()
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}

/// One window per container; closing it stops the stream.
@MainActor
final class LogWindows: NSObject, NSWindowDelegate {
    static let shared = LogWindows()
    private var windows: [String: (NSWindow, LogStore)] = [:]

    func open(api: DockerAPI, id: String, name: String, openInTerminal: @escaping () -> Void) {
        if let (w, _) = windows[id] {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let store = LogStore(api: api, containerID: id, name: name)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Logs: \(name)"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: LogView(store: store, openInTerminal: openInTerminal))
        w.setFrameAutosaveName("ColimaBarLogs")
        w.delegate = self
        windows[id] = (w, store)
        store.start()
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow,
              let (id, entry) = windows.first(where: { $0.value.0 === w }) else { return }
        entry.1.stop()
        windows[id] = nil
    }
}
