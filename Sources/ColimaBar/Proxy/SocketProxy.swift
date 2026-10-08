import Darwin
import Foundation
import os

/// The auto-start proxy behind ColimaBar's stable socket (Paths.proxySocket),
/// and behind the socket of each profile (Paths.profileSocket, see
/// ProfileProxies).
///
/// Every docker client (shell DOCKER_HOST, launchd env for IDEs, the docker
/// context, testcontainers.properties) points at the stable path. The
/// `colimabar-PROFILE` contexts point at the profile sockets. While the VM is
/// up, connections are spliced byte-for-byte to Colima's socket, so attach,
/// exec, builds and log streams all work. While it's down, the first real
/// request starts Colima, waits for it, then continues on the same connection.
///
/// `docker` pings before every command (HEAD /_ping), and so do many idle
/// pollers. Pings are answered locally while the VM is down, so only a request
/// that actually does something (run, ps, build...) wakes it.
///
/// When ColimaBar quits or the feature is off, the path becomes a symlink to
/// Colima's socket, so clients keep working, just without auto-start.
/// `@unchecked Sendable`: `lock` guards every mutable property; the others are `let`.
final class SocketProxy: @unchecked Sendable {
    private let log = Logger(category: "proxy")
    private let lock = NSLock()
    /// The accept source of the listening socket. Its cancel handler closes
    /// the fd, so the fd number stays in use until no accept can run on it.
    private var listener: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "colimabar.proxy.accept")
    /// True while accept fails (for example EMFILE), so the log gets one
    /// error for each episode, not ten each second. Only `acceptQueue` uses it.
    private var acceptFailing = false
    private var _upstream: String
    private var _apiVersion: String?
    private var _wake: @Sendable () async -> Bool = { false }
    private var isWaking = false
    private var isHeld = false
    private var waiters: [DispatchSemaphore] = []
    private var lastWakeSucceeded = false
    private var conns: [Int: Connection] = [:]
    private var nextConn = 0

    /// One open client connection. `isWork` is true while its latest
    /// request does real work (see isWork(_:)).
    private struct Connection {
        let opened: Date
        var lastIO: Date
        var isWork: Bool
    }

    /// Opens a connection to Colima's socket (injectable for tests).
    let connectUpstream: @Sendable (String) -> Result<Int32, UnixSocket.Error>

    /// While the VM is down, or before its first request, a client that
    /// sends nothing for this many seconds is closed. Otherwise each idle
    /// client holds a thread and an fd forever. Spliced connections have no timeout:
    /// attach, logs and events streams can be silent for a long time.
    let idleTimeout: Int

    /// The largest request head (request line and headers) the VM-down path
    /// reads. A larger head gets 431 and the connection closes, so a client
    /// cannot make the proxy buffer without limit.
    static let maxHead = 64 * 1024

    /// The size of each copy buffer. A spliced connection has two. 16 KB
    /// still copies far faster than Lima's socket forward, and a burst of
    /// connections leaves less memory behind than with 64 KB.
    static let bufferSize = 16 * 1024

    /// How long a request waits for a wake. wake() must finish well inside it.
    /// wake() worst case: 300 s waiting for another start + 600 s for
    /// `colima start` (+10 s to kill it) + 60 s of readiness probes.
    static let waitBudget: TimeInterval = 20 * 60

    /// Where the socket lives (injectable for tests).
    let path: String

    /// The profile of a profile socket, for the log. Empty for the stable socket.
    let label: String

    init(
        upstream: String, path: String = Paths.proxySocket, idleTimeout: Int = 5 * 60, label: String = "",
        connectUpstream: @escaping @Sendable (String) -> Result<Int32, UnixSocket.Error> = {
            UnixSocket.tryConnect($0)
        }
    ) {
        _upstream = upstream
        self.path = path
        self.label = label
        self.idleTimeout = idleTimeout
        self.connectUpstream = connectUpstream
    }

    /// Starts Colima and returns once Docker is ready (or false on failure).
    /// The model sets it after init, because the closure captures the model.
    var wake: @Sendable () async -> Bool {
        get { lock.withLock { _wake } }
        set { lock.withLock { _wake = newValue } }
    }

    var upstream: String {
        get { lock.withLock { _upstream } }
        set {
            lock.withLock { _upstream = newValue }
            if !isRunning { linkStable(to: newValue) }
        }
    }

    /// Docker API version reported by the daemon, used to answer pings while
    /// the VM is stopped.
    var apiVersion: String? {
        get { lock.withLock { _apiVersion } }
        set { lock.withLock { _apiVersion = newValue } }
    }

    var isRunning: Bool { lock.withLock { listener != nil } }

    deinit {
        // A released source never runs its cancel handler, so the fd would leak.
        listener?.cancel()
    }

    /// The model holds the proxy while a wake of its upstream profile runs,
    /// also a wake that another proxy started. The stable socket and the
    /// profile socket of the selected profile share one upstream. A held
    /// proxy splices no request: each one waits for the shared wake.
    func holdForWake(_ on: Bool) {
        lock.withLock { isHeld = on }
    }

    func start() {
        guard !isRunning else { return }
        UnixSocket.makePrivateDir((path as NSString).deletingLastPathComponent)
        do {
            let fd = try UnixSocket.listen(path)
            // Non-blocking, so acceptPending() can drain the queue and return.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                self.acceptPending(fd, source)
            }
            // Only this handler closes the fd. GCD runs it after the last
            // event handler returns, so another listener cannot get the same
            // fd number while an accept can still run on it.
            source.setCancelHandler { close(fd) }
            lock.withLock { listener = source }
            source.activate()
            log.notice("proxy listening on \(self.path, privacy: .public)")
        } catch {
            log.error("proxy failed to listen: \(String(describing: error), privacy: .public)")
            linkStable(to: upstream)
        }
    }

    /// Stops accepting and leaves a symlink to Colima's socket in its place.
    func stop() {
        let source = takeListener()
        // Link first: a client that connects in between still reaches a live
        // listener, never a closed one (ECONNREFUSED).
        linkStable(to: upstream)
        source?.cancel()
    }

    /// Stops accepting and removes the socket path, for a profile that no
    /// longer exists. Nothing replaces the path.
    func remove() {
        let source = takeListener()
        unlink(path)
        source?.cancel()
    }

    private func takeListener() -> DispatchSourceRead? {
        lock.withLock {
            defer { listener = nil }
            return listener
        }
    }

    /// Atomically replaces `path` with a symlink to `target` (symlink at a
    /// temporary name, then rename), so clients never hit ENOENT in between.
    func linkStable(to target: String) {
        UnixSocket.makePrivateDir((path as NSString).deletingLastPathComponent)
        let tmp = path + ".lnk"
        unlink(tmp)
        if symlink(target, tmp) != 0 || rename(tmp, path) != 0 {
            log.error("couldn't link \(self.path, privacy: .public): errno \(errno)")
            unlink(tmp)
        }
    }

    // MARK: - Connections

    /// Accepts every waiting client, then returns. GCD calls it again when
    /// more clients wait.
    private func acceptPending(_ fd: Int32, _ source: DispatchSourceRead) {
        while !source.isCancelled {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let err = errno
                if err == EINTR || err == ECONNABORTED { continue }
                if err == EAGAIN || err == EWOULDBLOCK { return }
                // Out of fds (EMFILE/ENFILE) or similar: back off. The client
                // still waits, so GCD calls this again, and the proxy keeps
                // serving instead of leaving a socket nobody accepts on.
                if !acceptFailing { log.error("proxy accept failed: errno \(err)") }
                acceptFailing = true
                usleep(100_000)
                return
            }
            if acceptFailing { log.notice("proxy accepts again") }
            acceptFailing = false
            // A client socket inherits O_NONBLOCK from the listener on macOS.
            // serve() and splice() need blocking reads and writes.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            UnixSocket.configure(client, timeout: 0)
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    /// The result of trying Colima's socket.
    private enum Upstream {
        case up(Int32)
        /// Nothing listens there, or a wake runs: wait for the wake.
        case down
        /// Connecting failed for another reason, such as no free fds.
        case failed(Int32)
    }

    /// Not while a wake runs: Lima's ssh tunnel accepts connections seconds
    /// before dockerd and containerd are stable, so requests must wait for
    /// the readiness check in wake() like the one that triggered it. This
    /// includes a wake of the same profile that another proxy started
    /// (holdForWake).
    private func connectIfAwake() -> Upstream {
        if lock.withLock({ isWaking || isHeld }) { return .down }
        switch connectUpstream(upstream) {
        case .success(let fd): return .up(fd)
        case .failure(.socket(let err)): return Self.meansVMDown(err) ? .down : .failed(err)
        }
    }

    private func serve(_ client: Int32) {
        // Fast path: VM up, splice straight through without parsing anything.
        switch connectIfAwake() {
        case .up(let up):
            // Read the start of the first request to classify the connection
            // (auto-stop activity); the bytes are forwarded as they are.
            // A client that sends nothing closes after idleTimeout. splice()
            // removes the timeout again before it streams.
            UnixSocket.setTimeout(client, idleTimeout)
            let first = withUnsafeTemporaryAllocation(byteCount: 8192, alignment: 16) { buf -> (Data, Bool)? in
                guard let base = buf.baseAddress else { return nil }
                var n = read(client, base, buf.count)
                while n < 0, errno == EINTR { n = read(client, base, buf.count) }
                guard n > 0 else { return nil }
                let chunk = UnsafeRawBufferPointer(rebasing: buf[0..<n])
                return (Data(chunk), Self.isWork(Self.lastRequestLine(chunk)))
            }
            guard let first else {
                close(client)
                close(up)
                return
            }
            splice(client, up, initial: first.0, work: first.1)
            return
        case .failed(let err):
            refuse(client, err)
            return
        case .down:
            break
        }
        // An idle client closes after idleTimeout. splice() removes the
        // timeout again before it streams.
        UnixSocket.setTimeout(client, idleTimeout)
        let marker = Data("\r\n\r\n".utf8)
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: Self.bufferSize)
        while true {
            // Need one complete request head to decide what to do. Only the
            // new bytes (and the 3 before them) are searched on each read.
            var found = pending.range(of: marker)
            while found == nil {
                if pending.count >= Self.maxHead {
                    reply(
                        client, status: "431 Request Header Fields Too Large",
                        "ColimaBar refused a request head larger than \(Self.maxHead / 1024) KB.")
                    return
                }
                let n = read(client, &buf, buf.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    close(client)
                    return
                }
                let from = pending.startIndex + max(0, pending.count - (marker.count - 1))
                pending.append(buf, count: n)
                found = pending.range(of: marker, in: from..<pending.endIndex)
            }
            guard let head = found else {
                close(client)
                return
            }
            let requestLine =
                String(decoding: pending[..<head.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n").first ?? ""
            if let reply = pingReply(requestLine) {
                // VM may have come up meanwhile; prefer the real daemon.
                if case .up(let up) = connectIfAwake() {
                    splice(client, up, initial: pending, work: Self.isWork(requestLine))
                    return
                }
                guard UnixSocket.writeAll(client, reply) else {
                    close(client)
                    return
                }
                pending.removeSubrange(..<head.upperBound)
                continue
            }
            // The VM may have come up while this client was idle.
            switch connectIfAwake() {
            case .up(let up):
                splice(client, up, initial: pending, work: Self.isWork(requestLine))
                return
            case .failed(let err):
                refuse(client, err)
                return
            case .down:
                break
            }
            log.notice(
                "waking Colima\(self.label.isEmpty ? "" : " profile " + self.label, privacy: .public) for: \(Self.logTarget(requestLine), privacy: .public)"
            )
            guard waitForWake() else {
                reply503(client, Self.couldNotStart)
                return
            }
            switch connectUpstream(upstream) {
            case .success(let up):
                splice(client, up, initial: pending, work: Self.isWork(requestLine))
            case .failure(.socket(let err)) where !Self.meansVMDown(err):
                refuse(client, err)
            case .failure:
                reply503(client, Self.couldNotStart)
            }
            return
        }
    }

    /// Answers 503 when connecting to Colima's socket failed for a reason
    /// other than "VM down", for example EMFILE. Colima is not started.
    private func refuse(_ client: Int32, _ err: Int32) {
        let reason = String(cString: strerror(err))
        log.error("couldn't connect to Colima's socket: errno \(err) (\(reason, privacy: .public)); answering 503")
        reply503(
            client, "ColimaBar could not connect to the Colima socket: \(reason) (errno \(err)). Try again in a moment."
        )
    }

    /// The 503 message when a wake fails.
    private static let couldNotStart =
        "ColimaBar could not start Colima. Check the Colima log or start it from the menu bar."

    private func reply503(_ client: Int32, _ message: String) {
        reply(client, status: "503 Service Unavailable", message)
    }

    /// Sends a JSON error like the daemon's, then closes the connection.
    private func reply(_ client: Int32, status: String, _ message: String) {
        let body =
            (try? JSONSerialization.data(withJSONObject: ["message": message], options: [.withoutEscapingSlashes]))
            ?? Data(#"{"message":"ColimaBar error"}"#.utf8)
        let head =
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = UnixSocket.writeAll(client, Data(head.utf8) + body)
        close(client)
    }

    /// Open connections doing real work: a build, pull, push, load, save,
    /// import or commit (classified by the connection's latest request, see
    /// isWork). They count while open, even through a silent build step, up
    /// to `stall` without any bytes. Pollers' GETs and `docker events` never
    /// count. Auto-stop treats any of these as "not idle".
    func activeTransfers(now: Date = Date(), stall: TimeInterval = 30 * 60) -> Int {
        lock.withLock {
            conns.values.filter { $0.isWork && now.timeIntervalSince($0.lastIO) <= stall }.count
        }
    }

    /// Tests only: records a connection the way splice() does.
    func addConnection(work: Bool, lastIO: Date) {
        lock.withLock {
            nextConn += 1
            conns[nextConn] = Connection(opened: lastIO, lastIO: lastIO, isWork: work)
        }
    }

    private func touch(_ id: Int) {
        lock.withLock { conns[id]?.lastIO = Date() }
    }

    /// A locally generated /_ping response, or nil if this request isn't a
    /// ping or we don't know the daemon's API version yet.
    func pingReply(_ requestLine: String) -> Data? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD", let version = apiVersion else { return nil }
        let path = parts[1].split(separator: "?").first.map(String.init) ?? ""
        guard
            path == "/_ping"
                || (path.hasPrefix("/v") && path.hasSuffix("/_ping")
                    && path.dropFirst(2).dropLast(6).allSatisfy { $0.isNumber || $0 == "." })
        else { return nil }
        let head =
            "HTTP/1.1 200 OK\r\nApi-Version: \(version)\r\nDocker-Experimental: false\r\nOstype: linux\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\n"
        return Data((parts[0] == "HEAD" ? head : head + "OK").utf8)
    }

    /// The number of requests that wait for the current wake. Tests use it
    /// to know that the proxy holds a request, instead of a fixed sleep.
    var wakeWaiters: Int { lock.withLock { waiters.count } }

    /// One wake per burst: the first caller starts Colima, the rest wait on it.
    private func waitForWake() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let first = lock.withLock { () -> Bool in
            waiters.append(sem)
            defer { isWaking = true }
            return !isWaking
        }
        if first {
            let wake = self.wake
            Task {
                let ok = await wake()
                let ws = self.lock.withLock { () -> [DispatchSemaphore] in
                    let ws = self.waiters
                    self.waiters = []
                    self.isWaking = false
                    self.lastWakeSucceeded = ok
                    return ws
                }
                for w in ws { w.signal() }
            }
        }
        // Longer than wake()'s own budget (start + readiness), so a slow start
        // is reported by wake() instead of a 503 while the VM still boots.
        guard sem.wait(timeout: .now() + Self.waitBudget) == .success else { return false }
        return lock.withLock { lastWakeSucceeded }
    }

    /// Copies bytes both ways until each side closes, half-closing as it goes
    /// so request/response streams (and hijacked attach/exec) end cleanly.
    private func splice(_ client: Int32, _ upstream: Int32, initial: Data, work: Bool = false) {
        // Streams can be silent for a long time: remove the idle timeout of
        // the VM-down path.
        UnixSocket.setTimeout(client, 0)
        if !initial.isEmpty, !UnixSocket.writeAll(upstream, initial) {
            close(client)
            close(upstream)
            return
        }
        let id = lock.withLock { () -> Int in
            nextConn += 1
            let now = Date()
            conns[nextConn] = Connection(opened: now, lastIO: now, isWork: work)
            return nextConn
        }
        defer { lock.withLock { conns[id] = nil } }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            copy(from: upstream, to: client, conn: id)
            // The daemon is done (response sent, container exited or daemon
            // died): unblock the other thread's read(client), or an idle
            // keep-alive client would hold 2 threads and 2 fds indefinitely.
            shutdown(client, SHUT_RD)
            done.signal()
        }
        copy(from: client, to: upstream, conn: id, classify: true)
        done.wait()
        close(client)
        close(upstream)
    }

    /// With `classify`, each chunk that starts a new request sets the
    /// connection's work flag from isWork, to true or back to false. The
    /// docker CLI sends HEAD /_ping first and then reuses the same keep-alive
    /// connection for the pull, push or build. A pooled client (docker-java)
    /// pulls once and then polls GET /containers/json on the same connection;
    /// the poll must not keep the VM awake.
    ///
    /// Each direction allocates one buffer for the whole connection. It is
    /// freed when the copy ends.
    private func copy(from src: Int32, to dst: Int32, conn: Int, classify: Bool = false) {
        withUnsafeTemporaryAllocation(byteCount: Self.bufferSize, alignment: 16) { buf in
            guard let base = buf.baseAddress else { return }
            var lastTouch = Date.distantPast
            while true {
                let n = read(src, base, buf.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                if classify {
                    // Reads the bytes in place. A chunk with several requests
                    // takes the work flag of the last one.
                    let line = Self.lastRequestLine(UnsafeRawBufferPointer(rebasing: buf[0..<n]))
                    if !line.isEmpty {
                        let work = Self.isWork(line)
                        lock.withLock { conns[conn]?.isWork = work }
                    }
                }
                let now = Date()
                if now.timeIntervalSince(lastTouch) >= 1 {
                    touch(conn)
                    lastTouch = now
                }
                var off = 0
                while off < n {
                    let w = write(dst, base + off, n - off)
                    if w <= 0 {
                        shutdown(src, SHUT_RD)
                        shutdown(dst, SHUT_WR)
                        return
                    }
                    off += w
                }
            }
            shutdown(dst, SHUT_WR)
        }
    }
}
