import AppKit
import Observation

/// Live log state for one container. Bytes arrive on a background thread,
/// are parsed there, and published to the UI four times a second at most.
/// While the window is minimized or covered, nothing is published.
@MainActor @Observable
final class LogStore {
    let containerID: String
    let name: String
    var lines: [LogLine] = []
    /// `lines` after the search and stderr filters. Kept up to date
    /// incrementally: new lines are filtered once as they arrive, and only a
    /// filter change re-filters everything.
    private(set) var visible: [LogLine] = []
    /// The index in `visible` of the first line that the list renders.
    /// See `LogTail`.
    private(set) var tailStart = 0
    var search = "" { didSet { if search != oldValue { refilter() } } }
    var follow = true { didSet { if follow && !oldValue { updateTail() } } }
    var showTime = true
    var wrap = true
    var stderrOnly = false { didSet { if stderrOnly != oldValue { refilter() } } }
    var status = Status.connecting

    /// The state that the window's footer shows.
    enum Status: Equatable {
        case connecting
        case live
        /// The stream is down: why, and what happens next.
        case down(String)

        var text: String {
            switch self {
            case .connecting: "Connecting…"
            case .live: "Live"
            case .down(let message): message
            }
        }
    }

    @ObservationIgnored private let api: DockerAPI
    @ObservationIgnored private var handle: StreamHandle?
    @ObservationIgnored private let buffer: LogBuffer
    @ObservationIgnored private var closed = false
    /// False while the window is minimized or not visible on screen.
    @ObservationIgnored private var onScreen = true
    /// The time of the last log request that the daemon accepted.
    @ObservationIgnored private var lastStart: Date?
    /// Bytes of text in `lines`.
    @ObservationIgnored private var textBytes = 0
    let maxLines: Int
    let maxBytes: Int

    init(
        api: DockerAPI, containerID: String, name: String, maxLines: Int = LogLimits.maxLines,
        maxBytes: Int = LogLimits.maxBytes
    ) {
        self.api = api
        self.containerID = containerID
        self.name = name
        self.maxLines = maxLines
        self.maxBytes = maxBytes
        self.buffer = LogBuffer(cap: maxLines, byteCap: maxBytes)
    }

    private func filtered(_ batch: [LogLine]) -> [LogLine] {
        var m = LogFilter.Matcher(query: search)
        let errOnly = stderrOnly
        return batch.filter { (!errOnly || $0.isStderr) && m.matches($0.text) }
    }

    private func refilter() {
        visible = filtered(lines)
        setTailStart(LogTail.reset(count: visible.count))
    }

    /// The lines that the list renders: the newest part of `visible`.
    var shown: ArraySlice<LogLine> { visible[min(tailStart, visible.count)...] }

    /// Writes only a changed value, so that the list does not re-render
    /// for nothing.
    private func setTailStart(_ v: Int) {
        if v != tailStart { tailStart = v }
    }

    /// Called when the window is minimized, covered or shown again. While it
    /// is hidden, lines wait in `buffer` (capped). The first flush after it
    /// shows again publishes them.
    func setOnScreen(_ on: Bool) {
        guard on != onScreen else { return }
        onScreen = on
        if on { ingest(buffer.drain()) }
    }

    func start() {
        closed = false
        Task { await connect(tail: LogLimits.initialTail) }
    }

    func stop() {
        closed = true
        handle?.cancel()
        handle = nil
    }

    func clear() {
        lines.removeAll()
        visible.removeAll()
        textBytes = 0
        setTailStart(0)
    }

    /// All lines that pass the filters, also those that the list does not
    /// render.
    var allText: String {
        visible.map { showTime ? "\($0.time)  \($0.text)" : $0.text }.joined(separator: "\n")
    }

    private func connect(tail: Int) async {
        guard !closed else { return }
        let asked = Date()
        // No reply means the socket refused or timed out, for example while
        // `colima restart` runs. Only HTTP 404 means the container is gone.
        guard let r = await api.get("/containers/\(containerID)/json") else {
            reconnect(tail: tail, status: "Docker is not reachable. Retrying…")
            return
        }
        if r.status == 404 {
            status = .down("This container has been removed, so its logs are gone.")
            return
        }
        guard r.ok, let j = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
            let config = j["Config"] as? [String: Any]
        else {
            reconnect(tail: tail, status: "Docker could not inspect the container (HTTP \(r.status)). Retrying…")
            return
        }
        let tty = config["Tty"] as? Bool ?? false
        // The window may have closed while we waited for the inspect call.
        guard !closed else { return }
        let q = Self.logQuery(lastTimestamp: buffer.lastTimestamp, lastStart: lastStart, tail: tail)
        // Prefer the daemon's clock: the VM clock can drift from the Mac's,
        // for example after sleep. The header has whole seconds only.
        lastStart = r.headers["date"].flatMap(Self.httpDate)?.addingTimeInterval(-1) ?? asked
        status = .live
        let box = DemuxBox(LogDemuxer(tty: tty))
        let buffer = self.buffer
        handle = api.streamRaw(
            "/containers/\(containerID)/logs?\(q)",
            onData: { [weak self] data in
                // Parse here, off the main thread. Only the first push after a
                // flush hops to the main actor.
                let batch = box.feed(data)
                guard !batch.lines.isEmpty, buffer.push(batch.lines, lastTimestamp: batch.lastTimestamp)
                else { return }
                Task { @MainActor in await self?.flush() }
            },
            onEnd: { [weak self] h in
                Task { @MainActor in
                    guard let self, self.handle === h else { return }
                    if let s = h.status, !(200..<300).contains(s) {
                        self.status = .down("Docker refused the log request (HTTP \(s)).")
                        return
                    }
                    self.ended()
                }
            })
    }

    /// The query for a log request. After the first line it asks for
    /// everything after that line. If no line has arrived yet but an earlier
    /// request ran, it asks for everything since that request: a container
    /// that starts and dies between two attempts still shows its output
    /// (often the reason it crashed). No line arrived, so none repeats.
    nonisolated static func logQuery(lastTimestamp: String?, lastStart: Date?, tail: Int) -> String {
        var q = "follow=1&stdout=1&stderr=1&timestamps=1"
        if let ts = lastTimestamp, let since = sinceParam(ts) {
            // Everything after the last line we have; `tail` would cut it.
            q += "&tail=all&since=\(since)"
        } else if let lastStart {
            q += "&tail=all&since=\(sinceParam(date: lastStart))"
        } else {
            q += "&tail=\(tail)"
        }
        return q
    }

    /// A date as UNIX "seconds.nanoseconds" for `since`.
    nonisolated static func sinceParam(date: Date) -> String {
        let t = date.timeIntervalSince1970
        let secs = Int64(t.rounded(.down))
        return formatSince(secs: secs, nanos: Int64(((t - Double(secs)) * 1e9).rounded()))
    }

    /// Parses an HTTP "Date" header, for example "Tue, 06 Oct 2026 10:00:00 GMT".
    nonisolated static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    /// The Engine API takes `since` as UNIX "seconds.nanoseconds", not the
    /// RFC 3339 timestamps it prints. `since` is inclusive, so this adds 1 ns
    /// to skip the line we already have.
    nonisolated static func sinceParam(_ ts: String) -> String? {
        guard let t = LogTime.parse(ts[...]) else { return nil }
        return formatSince(secs: t.secs, nanos: t.nanos + 1)
    }

    /// "seconds.nanoseconds" with nine digits after the point. `nanos` may
    /// be one full second; it then carries into `secs`.
    nonisolated private static func formatSince(secs: Int64, nanos: Int64) -> String {
        var secs = secs
        var nanos = nanos
        if nanos >= 1_000_000_000 {
            nanos -= 1_000_000_000
            secs += 1
        }
        let n = String(nanos)
        return "\(secs)." + String(repeating: "0", count: 9 - n.count) + n
    }

    /// Waits so that lines arriving in the next `LogLimits.flushDelay` join this batch, then
    /// publishes the batch. While the window is hidden, it publishes nothing:
    /// the buffer then asks for no more flushes until `setOnScreen(true)`.
    private func flush() async {
        try? await Task.sleep(for: LogLimits.flushDelay)
        guard onScreen else { return }
        ingest(buffer.drain())
    }

    /// Appends a batch of lines and filters only the new ones.
    func ingest(_ batch: [LogLine]) {
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        textBytes += batch.reduce(0) { $0 + LogTrim.size($1) }
        visible.append(contentsOf: filtered(batch))
        var start = tailStart
        if LogLimits.needsTrim(lines: lines.count, bytes: textBytes, maxLines: maxLines, maxBytes: maxBytes) {
            let d = LogTrim.dropCount(lines, bytes: textBytes, maxLines: maxLines, maxBytes: maxBytes)
            lines.removeFirst(d.count)
            textBytes -= d.bytes
            let first = lines.first?.id ?? Int.max
            let gone = visible.firstIndex(where: { $0.id >= first }) ?? visible.count
            visible.removeFirst(gone)
            start -= gone
        }
        updateTail(from: start)
    }

    /// Moves the start of the rendered lines when they pass the limit.
    private func updateTail(from start: Int? = nil) {
        setTailStart(
            LogTail.start(
                current: start ?? tailStart, count: visible.count,
                slack: follow ? 0 : LogTail.slack))
    }

    /// Stream ends when the container stops or restarts: keep the window and
    /// reconnect from the last timestamp once it's back.
    private func ended() {
        reconnect(tail: 0, status: "Container stopped. Waiting for it to start…")
    }

    /// Shows `status` and tries again after `LogLimits.reconnectDelay`. A
    /// closed window stops the loop.
    private func reconnect(tail: Int, status: String) {
        guard !closed else { return }
        self.status = .down(status)
        Task {
            try? await Task.sleep(for: LogLimits.reconnectDelay)
            await connect(tail: tail)
        }
    }
}

/// Parsed lines from one read, and the newest timestamp among them.
private struct ParsedBatch {
    let lines: [LogLine]
    let lastTimestamp: String?
}

/// Thread-confined demuxer state for the background reader.
/// `@unchecked Sendable`: only the one stream reader thread calls feed(_:).
private final class DemuxBox: @unchecked Sendable {
    private var demux: LogDemuxer
    init(_ d: LogDemuxer) { demux = d }

    func feed(_ data: Data) -> ParsedBatch {
        var last: Substring?
        let lines = demux.feed(data).map { piece in
            let p = LogLine.parse(piece.text, isStderr: piece.isStderr)
            if let ts = p.timestamp { last = ts }
            return p.line
        }
        return ParsedBatch(lines: lines, lastTimestamp: last.map(String.init))
    }
}
