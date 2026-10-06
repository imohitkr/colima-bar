import AppKit
import Observation
import SwiftUI

struct LogLine: Identifiable, Equatable {
    /// Set by `LogBuffer` when the line enters the store.
    fileprivate(set) var id: Int
    let time: String     // HH:mm:ss.SSS, local time
    let text: String
    let stderr: Bool
    let lower: String    // text lower-cased once, for filtering

    init(id: Int, time: String, text: String, stderr: Bool) {
        self.id = id
        self.time = time
        self.text = text
        self.stderr = stderr
        self.lower = text.lowercased()
    }

    /// Builds a line from "2026-10-02T14:03:11.123456789Z message" on the
    /// reader thread. Also returns the timestamp, which `since` needs later.
    /// A line without a valid timestamp keeps all its text.
    static func parse(_ raw: String, stderr: Bool) -> (line: LogLine, timestamp: Substring?) {
        // RFC 3339 timestamps are at most 35 bytes, so look no further.
        if let sp = raw.utf8.prefix(40).firstIndex(of: 0x20) {
            let ts = raw[..<sp]
            if let t = LogTime.parse(ts) {
                let text = String(raw[raw.utf8.index(after: sp)...])
                return (LogLine(id: 0, time: LogTime.clock(secs: t.secs, nanos: t.nanos), text: text, stderr: stderr), ts)
            }
        }
        return (LogLine(id: 0, time: "", text: raw, stderr: stderr), nil)
    }
}

/// Parses Docker's RFC 3339 timestamps by hand. ISO8601DateFormatter costs
/// about 50 µs per line, which blocks the main thread at high log rates.
enum LogTime {
    /// Returns UNIX seconds and nanoseconds for "YYYY-MM-DDTHH:MM:SS[.f]Z".
    /// Accepts 0 to 9 fractional digits (more are cut) and a "Z" or
    /// "±HH:MM" zone. Returns nil for anything else.
    static func parse(_ ts: Substring) -> (secs: Int64, nanos: Int64)? {
        if let r = ts.utf8.withContiguousStorageIfAvailable({ parse($0) }) { return r }
        return Array(ts.utf8).withUnsafeBufferPointer { parse($0) }
    }

    private static func parse(_ b: UnsafeBufferPointer<UInt8>) -> (secs: Int64, nanos: Int64)? {
        guard b.count >= 20 else { return nil }
        func num(_ at: Int, _ len: Int) -> Int? {
            var v = 0
            for i in at..<(at + len) {
                let d = Int(b[i]) &- 48
                guard d >= 0, d <= 9 else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let y = num(0, 4), b[4] == 0x2D, let mo = num(5, 2), b[7] == 0x2D, let d = num(8, 2),
              b[10] == 0x54 || b[10] == 0x74,     // "T" or "t"
              let h = num(11, 2), b[13] == 0x3A, let mi = num(14, 2), b[16] == 0x3A, let s = num(17, 2),
              (1...12).contains(mo), d >= 1, d <= daysIn(month: mo, year: y),
              h <= 23, mi <= 59, s <= 60 else { return nil }
        var i = 19
        var nanos = 0
        if b[i] == 0x2E {     // "."
            i += 1
            var digits = 0
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                if digits < 9 { nanos = nanos * 10 + Int(b[i] - 0x30); digits += 1 }
                i += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<9 { nanos *= 10 }
        }
        guard i < b.count else { return nil }
        var offset = 0
        if b[i] == 0x5A || b[i] == 0x7A {     // "Z" or "z"
            i += 1
        } else if b[i] == 0x2B || b[i] == 0x2D {     // "+" or "-"
            guard i + 6 == b.count, let oh = num(i + 1, 2), b[i + 3] == 0x3A, let om = num(i + 4, 2),
                  oh <= 23, om <= 59 else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == 0x2B ? 1 : -1)
            i += 6
        } else {
            return nil
        }
        guard i == b.count else { return nil }
        let secs = daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s - offset
        return (Int64(secs), Int64(nanos))
    }

    private static func daysIn(month m: Int, year y: Int) -> Int {
        switch m {
        case 2: return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    /// This is Howard Hinnant's `days_from_civil` algorithm.
    private static func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Formats the time as HH:mm:ss.SSS in local time. It cuts (does not
    /// round) the nanoseconds to milliseconds.
    static func clock(secs: Int64, nanos: Int64) -> String {
        var t = time_t(secs)
        var parts = tm()
        guard localtime_r(&t, &parts) != nil else { return "" }
        let ms = Int(nanos / 1_000_000)
        return String(unsafeUninitializedCapacity: 12) { p in
            func put2(_ at: Int, _ v: Int) {
                p[at] = UInt8(48 + v / 10)
                p[at + 1] = UInt8(48 + v % 10)
            }
            put2(0, Int(parts.tm_hour)); p[2] = 0x3A
            put2(3, Int(parts.tm_min)); p[5] = 0x3A
            put2(6, Int(parts.tm_sec)); p[8] = 0x2E
            p[9] = UInt8(48 + ms / 100)
            put2(10, ms % 100)
            return 12
        }
    }
}

/// Case-insensitive search as a byte scan. Callers lower-case both sides
/// first, so the scan compares UTF-8 bytes exactly. This is about 30 times
/// faster than Foundation's `contains`.
enum LogFilter {
    static func needle(_ query: String) -> [UInt8] { Array(query.lowercased().utf8) }

    static func contains(_ lower: String, _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        if let r = lower.utf8.withContiguousStorageIfAvailable({ scan($0, needle) }) { return r }
        return Array(lower.utf8).withUnsafeBufferPointer { scan($0, needle) }
    }

    private static func scan(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard hay.count >= needle.count else { return false }
        return needle.withUnsafeBufferPointer { n in
            memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil
        }
    }
}

/// Docker multiplexes stdout/stderr of non-TTY containers into frames:
/// [stream(1), 0, 0, 0, size(4, big-endian)] + payload. TTY containers send
/// raw text. Keeps partial lines per stream between reads as raw bytes, so a
/// UTF-8 character split across reads or frames stays intact.
struct LogDemuxer {
    /// Longer lines are split into pieces of this size, so a stream that
    /// never sends "\n" cannot grow the partial buffer without limit.
    static let maxLineBytes = 16 * 1024
    /// Ends each piece of a split line except the last.
    static let splitMarker = " [continues]"

    let tty: Bool
    private var buffer = Data()
    private var partial: [Bool: Data] = [false: Data(), true: Data()]

    init(tty: Bool) { self.tty = tty }

    /// Returns complete lines as (text, isStderr).
    mutating func feed(_ data: Data) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        if tty {
            split(data, stderr: false, into: &out)
            return out
        }
        buffer.append(data)
        // Remove the used frames once at the end. Removing each frame from
        // the front would move the rest of the buffer every time.
        var b = buffer.startIndex
        while buffer.endIndex - b >= 8 {
            let size = Int(buffer[b + 4]) << 24 | Int(buffer[b + 5]) << 16 | Int(buffer[b + 6]) << 8 | Int(buffer[b + 7])
            guard buffer.endIndex - b >= 8 + size else { break }
            let payload = buffer[(b + 8)..<(b + 8 + size)]
            let isErr = buffer[b] == 2
            split(payload, stderr: isErr, into: &out)
            b += 8 + size
        }
        buffer.removeSubrange(buffer.startIndex..<b)
        return out
    }

    /// Splits on "\n" at the byte level and decodes only whole lines.
    private mutating func split(_ bytes: Data, stderr: Bool, into out: inout [(String, Bool)]) {
        var pending = partial[stderr] ?? Data()
        partial[stderr] = nil     // so the append below does not copy
        pending.append(bytes)
        var start = pending.startIndex
        while let nl = pending[start...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, pending[end - 1] == 0x0D { end -= 1 }   // drop "\r"
            start = Self.cutLong(pending, from: start, to: end, stderr: stderr, into: &out)
            out.append((String(decoding: pending[start..<end], as: UTF8.self), stderr))
            start = nl + 1
        }
        start = Self.cutLong(pending, from: start, to: pending.endIndex, stderr: stderr, into: &out)
        partial[stderr] = Data(pending[start...])
    }

    /// Emits full-size pieces while more than `maxLineBytes` remain, and
    /// returns where the rest starts. Never cuts inside a UTF-8 character.
    private static func cutLong(_ d: Data, from: Int, to end: Int, stderr: Bool,
                                into out: inout [(String, Bool)]) -> Int {
        var start = from
        while end - start > maxLineBytes {
            var cut = start + maxLineBytes
            while cut > start + 1, d[cut] & 0xC0 == 0x80 { cut -= 1 }   // continuation byte
            out.append((String(decoding: d[start..<cut], as: UTF8.self) + splitMarker, stderr))
            start = cut
        }
        return start
    }
}

/// Parsed lines wait here between the reader thread and the next flush on
/// the main thread. It keeps at most `cap` lines and drops the oldest, so a
/// slow main thread cannot make memory grow without limit.
final class LogBuffer: @unchecked Sendable {
    let cap: Int
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var nextID = 0
    private var last: String?
    private var flushPending = false

    init(cap: Int) { self.cap = cap }

    /// Gives the lines their ids and stores them. Returns true when the
    /// caller must schedule a flush; one is already pending otherwise.
    func push(_ new: [LogLine], lastTimestamp: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lines.reserveCapacity(lines.count + new.count)
        for var l in new {
            l.id = nextID
            nextID += 1
            lines.append(l)
        }
        if let lastTimestamp { last = lastTimestamp }
        // Trim in batches, so each push does not move every line.
        if lines.count > cap + LogStore.trimSlack { lines.removeFirst(lines.count - cap) }
        guard !flushPending, !lines.isEmpty else { return false }
        flushPending = true
        return true
    }

    /// Takes all waiting lines (at most `cap`) and allows the next flush.
    func drain() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        flushPending = false
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        let out = lines
        lines = []
        return out
    }

    /// The timestamp of the newest line, as Docker sent it. `since` needs
    /// its full nanosecond precision on reconnect.
    var lastTimestamp: String? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// Live log state for one container. Bytes arrive on a background thread,
/// are parsed there, and published to the UI ten times a second at most.
@MainActor @Observable
final class LogStore {
    let containerID: String
    let name: String
    var lines: [LogLine] = []
    /// `lines` after the search and stderr filters. Kept up to date
    /// incrementally: new lines are filtered once as they arrive, and only a
    /// filter change re-filters everything.
    private(set) var visible: [LogLine] = []
    var search = "" { didSet { if search != oldValue { refilter() } } }
    var follow = true
    var showTime = true
    var wrap = true
    var stderrOnly = false { didSet { if stderrOnly != oldValue { refilter() } } }
    var status = "Connecting…"

    @ObservationIgnored private let api: DockerAPI
    @ObservationIgnored private var handle: StreamHandle?
    @ObservationIgnored private let buffer: LogBuffer
    @ObservationIgnored private var closed = false
    let maxLines: Int
    /// `lines` may grow this far past `maxLines` before a trim. Trimming in
    /// batches keeps the cost of `removeFirst` low per line.
    nonisolated static let trimSlack = 2000

    init(api: DockerAPI, containerID: String, name: String, maxLines: Int = 20_000) {
        self.api = api
        self.containerID = containerID
        self.name = name
        self.maxLines = maxLines
        self.buffer = LogBuffer(cap: maxLines)
    }

    private func matches(_ l: LogLine, _ needle: [UInt8]) -> Bool {
        (!stderrOnly || l.stderr) && LogFilter.contains(l.lower, needle)
    }

    private func refilter() {
        let n = LogFilter.needle(search)
        visible = lines.filter { matches($0, n) }
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

    func clear() {
        lines.removeAll()
        visible.removeAll()
    }

    var allText: String {
        visible.map { showTime ? "\($0.time)  \($0.text)" : $0.text }.joined(separator: "\n")
    }

    private func connect(tail: Int) async {
        guard !closed else { return }
        // No reply means the socket refused or timed out, for example while
        // `colima restart` runs. Only HTTP 404 means the container is gone.
        guard let r = await api.get("/containers/\(containerID)/json") else {
            reconnect(tail: tail, status: "Docker is not reachable. Retrying…")
            return
        }
        if r.status == 404 {
            status = "This container has been removed, so its logs are gone."
            return
        }
        guard r.ok, let j = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let config = j["Config"] as? [String: Any] else {
            reconnect(tail: tail, status: "Docker could not inspect the container (HTTP \(r.status)). Retrying…")
            return
        }
        let tty = config["Tty"] as? Bool ?? false
        // The window may have closed while we waited for the inspect call.
        guard !closed else { return }
        var q = "follow=1&stdout=1&stderr=1&timestamps=1"
        if let ts = buffer.lastTimestamp, let since = Self.sinceParam(ts) {
            // Everything after the last line we have; `tail` would cut it.
            q += "&tail=all&since=\(since)"
        } else {
            q += "&tail=\(tail)"
        }
        status = "Live"
        let box = DemuxBox(LogDemuxer(tty: tty))
        let buffer = self.buffer
        handle = api.streamRaw("/containers/\(containerID)/logs?\(q)", onData: { [weak self] data in
            // Parse here, off the main thread. Only the first push after a
            // flush hops to the main actor.
            let (lines, ts) = box.feed(data)
            guard !lines.isEmpty, buffer.push(lines, lastTimestamp: ts) else { return }
            Task { @MainActor in await self?.flush() }
        }, onEnd: { [weak self] h in
            Task { @MainActor in
                guard let self, self.handle === h else { return }
                if let s = h.status, !(200..<300).contains(s) {
                    self.status = "Docker refused the log request (HTTP \(s))."
                    return
                }
                self.ended()
            }
        })
    }

    /// The Engine API takes `since` as UNIX "seconds.nanoseconds", not the
    /// RFC 3339 timestamps it prints. `since` is inclusive, so this adds 1 ns
    /// to skip the line we already have.
    nonisolated static func sinceParam(_ ts: String) -> String? {
        guard let t = LogTime.parse(ts[...]) else { return nil }
        var secs = t.secs
        var nanos = t.nanos + 1
        if nanos >= 1_000_000_000 { nanos -= 1_000_000_000; secs += 1 }
        let n = String(nanos)
        return "\(secs)." + String(repeating: "0", count: 9 - n.count) + n
    }

    /// Waits so that lines arriving in the next 100 ms join this batch, then
    /// publishes the batch.
    private func flush() async {
        try? await Task.sleep(for: .milliseconds(100))
        ingest(buffer.drain())
    }

    /// Appends a batch of lines and filters only the new ones.
    func ingest(_ batch: [LogLine]) {
        guard !batch.isEmpty else { return }
        let n = LogFilter.needle(search)
        lines.append(contentsOf: batch)
        visible.append(contentsOf: batch.filter { matches($0, n) })
        if lines.count > maxLines + Self.trimSlack {
            lines.removeFirst(lines.count - maxLines)
            if let first = lines.first?.id {
                visible.removeFirst(visible.firstIndex(where: { $0.id >= first }) ?? visible.count)
            }
        }
    }

    /// Stream ends when the container stops or restarts: keep the window and
    /// reconnect from the last timestamp once it's back.
    private func ended() {
        reconnect(tail: 0, status: "Container stopped. Waiting for it to start…")
    }

    /// Shows `status` and tries again after 2 s. A closed window stops the loop.
    private func reconnect(tail: Int, status: String) {
        guard !closed else { return }
        self.status = status
        Task {
            try? await Task.sleep(for: .seconds(2))
            await connect(tail: tail)
        }
    }

    /// HH:mm:ss.SSS in local time, or "" if `ts` is not a valid timestamp.
    nonisolated static func clock(_ ts: String) -> String {
        guard let t = LogTime.parse(ts[...]) else { return "" }
        return LogTime.clock(secs: t.secs, nanos: t.nanos)
    }
}

/// Thread-confined demuxer state for the background reader.
private final class DemuxBox: @unchecked Sendable {
    private var demux: LogDemuxer
    init(_ d: LogDemuxer) { demux = d }

    /// Returns parsed lines and the newest timestamp among them.
    func feed(_ data: Data) -> ([LogLine], String?) {
        var last: Substring?
        let lines = demux.feed(data).map { raw, isErr in
            let p = LogLine.parse(raw, stderr: isErr)
            if let ts = p.timestamp { last = ts }
            return p.line
        }
        return (lines, last.map(String.init))
    }
}

struct LogView: View {
    @Bindable var store: LogStore
    var openInTerminal: () -> Void

    // This body reads no line data. Each flush re-renders only the list,
    // the follow scroller and the footer.
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
            LogList(store: store)
            Divider()
            LogFooter(store: store)
            HintBar()
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}

/// The visible lines. It reads `visible` but not `lines`, so lines that the
/// filter hides do not re-render it.
private struct LogList: View {
    let store: LogStore

    var body: some View {
        let showTime = store.showTime
        let wrap = store.wrap
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.visible) { line in
                        LogRow(line: line, showTime: showTime, wrap: wrap)
                            .id(line.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(FollowScroller(store: store, proxy: proxy))
        }
    }
}

private struct LogRow: View {
    let line: LogLine
    let showTime: Bool
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showTime {
                Text(line.time).foregroundStyle(.tertiary)
            }
            Text(line.text)
                .foregroundStyle(line.stderr ? Color.red.opacity(0.9) : .primary)
                .fixedSize(horizontal: !wrap, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Scrolls to the newest visible line when lines arrive and Follow is on.
/// It is a separate view, so reading `lines` here does not re-render the list.
private struct FollowScroller: View {
    let store: LogStore
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: store.lines.last?.id) {
                if store.follow, let last = store.visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
    }
}

private struct LogFooter: View {
    let store: LogStore

    var body: some View {
        HStack {
            Circle().fill(store.status == "Live" ? Color.green : .orange).frame(width: 6, height: 6)
            Text(store.status)
            Spacer()
            Text("\(store.visible.count) of \(store.lines.count) lines").monospacedDigit()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
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
