import Darwin
import Foundation
import os

/// Small POSIX helpers shared by the API client and the proxy.
enum UnixSocket {
    static func connect(_ path: String, timeout: Int = 0) -> Int32? {
        try? tryConnect(path, timeout: timeout).get()
    }

    /// Like connect, but a failure carries the errno, so the caller can tell
    /// "nothing listens there" (ENOENT, ECONNREFUSED) from "out of fds"
    /// (EMFILE, ENFILE).
    static func tryConnect(_ path: String, timeout: Int = 0) -> Result<Int32, ProxyError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket(errno)) }
        guard var addr = address(path) else { close(fd); return .failure(.socket(ENAMETOOLONG)) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else {
            let err = errno
            close(fd)
            return .failure(.socket(err))
        }
        configure(fd, timeout: timeout)
        return .success(fd)
    }

    static func canConnect(_ path: String) -> Bool {
        guard let fd = connect(path) else { return false }
        close(fd)
        return true
    }

    /// Binds at `path.tmp`, then renames it over `path`. The rename is atomic,
    /// so clients never see a moment with no socket (or a dead one) at `path`.
    static func listen(_ path: String) throws -> Int32 {
        let tmp = path + ".tmp"
        unlink(tmp)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError.socket(errno) }
        guard var addr = address(tmp) else { close(fd); throw ProxyError.socket(ENAMETOOLONG) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, chmod(tmp, 0o600) == 0, Darwin.listen(fd, 128) == 0, rename(tmp, path) == 0 else {
            let err = errno
            close(fd)
            unlink(tmp)
            throw ProxyError.socket(err)
        }
        return fd
    }

    /// Creates the socket's directory. ColimaBar's own cache directory is
    /// also made private to this user (0700); any other directory (tests) is
    /// left as it is.
    static func makePrivateDir(_ dir: String) {
        let own = (dir as NSString).standardizingPath == (Paths.cacheDir as NSString).standardizingPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: own ? [.posixPermissions: 0o700] : nil)
        if own { chmod(dir, 0o700) }
    }

    static func configure(_ fd: Int32, timeout: Int) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if timeout > 0 { setTimeout(fd, timeout) }
    }

    /// Sets the read and write timeout in seconds. 0 removes it.
    static func setTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}

enum ProxyError: Error { case socket(Int32) }

/// The per-process limit on open files (RLIMIT_NOFILE).
enum FileLimit {
    /// The proxy uses 2 fds per spliced connection, and each stats stream
    /// and log window uses 1 more. launchd starts apps with a soft limit of
    /// 256, which a busy dashboard and a few IDE clients can reach.
    static let wanted: rlim_t = 8192

    /// Raises the soft limit to `target`, capped by the hard limit and
    /// OPEN_MAX. It never lowers the limit. Returns the soft limit after
    /// the call.
    @discardableResult
    static func raise(to target: rlim_t = wanted) -> rlim_t {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return 0 }
        // macOS refuses RLIM_INFINITY and values above OPEN_MAX here.
        var want = min(target, lim.rlim_max, rlim_t(OPEN_MAX))
        guard want > lim.rlim_cur else { return lim.rlim_cur }
        var next = lim
        next.rlim_cur = want
        if setrlimit(RLIMIT_NOFILE, &next) != 0 {
            // kern.maxfilesperproc can be lower than OPEN_MAX: try that.
            var perProc: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("kern.maxfilesperproc", &perProc, &size, nil, 0) == 0, perProc > 0 {
                want = min(want, rlim_t(perProc))
                next.rlim_cur = want
                if want > lim.rlim_cur { setrlimit(RLIMIT_NOFILE, &next) }
            }
        }
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return 0 }
        return lim.rlim_cur
    }
}

/// The auto-start proxy behind ColimaBar's stable socket (Paths.proxySocket).
///
/// Every docker client (shell DOCKER_HOST, launchd env for IDEs, the docker
/// context, testcontainers.properties) points at that one path. While the VM is
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
final class SocketProxy: @unchecked Sendable {
    private let log = Logger(subsystem: "com.imohitkr.ColimaBar", category: "proxy")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var _upstream: String
    private var _apiVersion: String?
    private var waking = false
    private var waiters: [DispatchSemaphore] = []
    private var wakeOK = false
    private var conns: [Int: (opened: Date, lastIO: Date, work: Bool)] = [:]
    private var nextConn = 0

    /// Starts Colima and returns once Docker is ready (or false on failure).
    var wake: @Sendable () async -> Bool = { false }

    /// Opens a connection to Colima's socket (injectable for tests).
    var connectUpstream: @Sendable (String) -> Result<Int32, ProxyError> = { UnixSocket.tryConnect($0) }

    /// While the VM is down, a client that sends nothing for this many
    /// seconds is closed. Otherwise each idle keep-alive client holds a
    /// thread and an fd forever. Spliced connections have no timeout:
    /// attach, logs and events streams can be silent for a long time.
    var idleTimeout = 5 * 60

    /// How long a request waits for a wake. wake() must finish well inside it.
    /// wake() worst case: 300 s waiting for another start + 600 s for
    /// `colima start` (+10 s to kill it) + 60 s of readiness probes.
    static let waitBudget: TimeInterval = 20 * 60

    /// Where the stable socket lives (injectable for tests).
    let path: String

    init(upstream: String, path: String = Paths.proxySocket) {
        _upstream = upstream
        self.path = path
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

    var isRunning: Bool { lock.withLock { listenFD >= 0 } }

    func start() {
        guard !isRunning else { return }
        UnixSocket.makePrivateDir((path as NSString).deletingLastPathComponent)
        do {
            let fd = try UnixSocket.listen(path)
            lock.withLock { listenFD = fd }
            log.notice("proxy listening on \(self.path, privacy: .public)")
            Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
        } catch {
            log.error("proxy failed to listen: \(String(describing: error), privacy: .public)")
            linkStable(to: upstream)
        }
    }

    /// Stops accepting and leaves a symlink to Colima's socket in its place.
    func stop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = listenFD
            listenFD = -1
            return fd
        }
        // Link first: a client that connects in between still reaches a live
        // listener, never a closed one (ECONNREFUSED).
        linkStable(to: upstream)
        if fd >= 0 { close(fd) }
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

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let err = errno
                // stop() closed (or replaced) the listening socket: we're done.
                if lock.withLock({ listenFD != fd }) { return }
                if err == EINTR || err == ECONNABORTED { continue }
                // Out of fds (EMFILE/ENFILE) or similar: back off and keep
                // serving instead of leaving a socket nobody accepts on.
                log.error("proxy accept failed: errno \(err)")
                usleep(100_000)
                continue
            }
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

    /// Only ENOENT (no socket file) and ECONNREFUSED (stale socket file)
    /// mean that the VM is down. Other errors, such as EMFILE when this
    /// process runs out of fds, must not start Colima.
    static func meansVMDown(_ err: Int32) -> Bool { err == ENOENT || err == ECONNREFUSED }

    /// Not while a wake runs: Lima's ssh tunnel accepts connections seconds
    /// before dockerd and containerd are stable, so requests must wait for
    /// the readiness check in wake() like the one that triggered it.
    private func connectIfAwake() -> Upstream {
        if lock.withLock({ waking }) { return .down }
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
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &buf, buf.count)
            guard n > 0 else { close(client); close(up); return }
            let first = Data(buf[0..<n])
            let line = String(decoding: first.prefix { $0 != 0x0D && $0 != 0x0A }, as: UTF8.self)
            splice(client, up, initial: first, work: Self.isWork(line))
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
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            // Need one complete request head to decide what to do.
            while pending.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(client, &buf, buf.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { close(client); return }
                pending.append(buf, count: n)
            }
            let head = pending.range(of: Data("\r\n\r\n".utf8))!
            let requestLine = String(decoding: pending[..<head.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n").first ?? ""
            if let reply = pingReply(requestLine) {
                // VM may have come up meanwhile; prefer the real daemon.
                if case .up(let up) = connectIfAwake() {
                    splice(client, up, initial: pending, work: Self.isWork(requestLine))
                    return
                }
                guard UnixSocket.writeAll(client, reply) else { close(client); return }
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
            log.notice("waking Colima for: \(requestLine, privacy: .public)")
            guard waitForWake() else {
                reply503(client, "ColimaBar could not start Colima. Check the Colima log or start it from the menu bar.")
                return
            }
            switch connectUpstream(upstream) {
            case .success(let up):
                splice(client, up, initial: pending, work: Self.isWork(requestLine))
            case .failure(.socket(let err)) where !Self.meansVMDown(err):
                refuse(client, err)
            case .failure:
                reply503(client, "ColimaBar could not start Colima. Check the Colima log or start it from the menu bar.")
            }
            return
        }
    }

    /// Answers 503 when connecting to Colima's socket failed for a reason
    /// other than "VM down", for example EMFILE. Colima is not started.
    private func refuse(_ client: Int32, _ err: Int32) {
        let reason = String(cString: strerror(err))
        log.error("couldn't connect to Colima's socket: errno \(err) (\(reason, privacy: .public)); answering 503")
        reply503(client, "ColimaBar could not connect to the Colima socket: \(reason) (errno \(err)). Try again in a moment.")
    }

    private func reply503(_ client: Int32, _ message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["message": message], options: [.withoutEscapingSlashes]))
            ?? Data(#"{"message":"ColimaBar error"}"#.utf8)
        let head = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = UnixSocket.writeAll(client, Data(head.utf8) + body)
        close(client)
    }

    /// Open connections doing real work: a build, pull, push, load, save,
    /// import or commit (classified by the connection's first request, see
    /// isWork). They count while open, even through a silent build step, up
    /// to `stall` without any bytes. Pollers' GETs and `docker events` never
    /// count. Auto-stop treats any of these as "not idle".
    func activeTransfers(now: Date = Date(), stall: TimeInterval = 30 * 60) -> Int {
        lock.withLock {
            conns.values.filter { $0.work && now.timeIntervalSince($0.lastIO) <= stall }.count
        }
    }

    /// The first line of a chunk, if the chunk could start an HTTP request.
    static func requestLine(_ buf: [UInt8], _ n: Int) -> String {
        let head = buf[0..<min(n, 512)]
        guard let first = head.first, first >= 0x41, first <= 0x5A else { return "" }   // method: A-Z
        return String(decoding: head.prefix { $0 != 0x0D && $0 != 0x0A }, as: UTF8.self)
    }

    /// Whether an HTTP request line starts long-running work on the daemon.
    static func isWork(_ requestLine: String) -> Bool {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let method = parts[0]
        var path = String(parts[1].split(separator: "?").first ?? "")
        // Drop the API version prefix: /v1.54/build -> /build
        if path.hasPrefix("/v"), let slash = path.dropFirst().firstIndex(of: "/") { path = String(path[slash...]) }
        if path == "/session" || path.hasPrefix("/grpc") { return true }   // BuildKit
        guard method == "POST" || method == "GET" else { return false }
        if method == "GET" { return path == "/images/get" || (path.hasPrefix("/images/") && path.hasSuffix("/get")) }   // save
        return path == "/build" || path == "/images/create" || path == "/images/load" || path == "/commit"
            || (path.hasPrefix("/images/") && path.hasSuffix("/push"))
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
        guard path == "/_ping" || (path.hasPrefix("/v") && path.hasSuffix("/_ping")
                                   && path.dropFirst(2).dropLast(6).allSatisfy { $0.isNumber || $0 == "." }) else { return nil }
        let head = "HTTP/1.1 200 OK\r\nApi-Version: \(version)\r\nDocker-Experimental: false\r\nOstype: linux\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\n"
        return Data((parts[0] == "HEAD" ? head : head + "OK").utf8)
    }

    /// One wake per burst: the first caller starts Colima, the rest wait on it.
    private func waitForWake() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let first = lock.withLock { () -> Bool in
            waiters.append(sem)
            defer { waking = true }
            return !waking
        }
        if first {
            let wake = self.wake
            Task {
                let ok = await wake()
                let ws = self.lock.withLock { () -> [DispatchSemaphore] in
                    let ws = self.waiters
                    self.waiters = []
                    self.waking = false
                    self.wakeOK = ok
                    return ws
                }
                ws.forEach { $0.signal() }
            }
        }
        // Longer than wake()'s own budget (start + readiness), so a slow start
        // is reported by wake() instead of a 503 while the VM still boots.
        guard sem.wait(timeout: .now() + Self.waitBudget) == .success else { return false }
        return lock.withLock { wakeOK }
    }

    /// Copies bytes both ways until each side closes, half-closing as it goes
    /// so request/response streams (and hijacked attach/exec) end cleanly.
    private func splice(_ client: Int32, _ upstream: Int32, initial: Data, work: Bool = false) {
        // Streams can be silent for a long time: remove the idle timeout of
        // the VM-down path.
        UnixSocket.setTimeout(client, 0)
        if !initial.isEmpty, !UnixSocket.writeAll(upstream, initial) {
            close(client); close(upstream); return
        }
        let id = lock.withLock { () -> Int in
            nextConn += 1
            conns[nextConn] = (Date(), Date(), work)
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
        copy(from: client, to: upstream, conn: id, classify: !work)
        done.wait()
        close(client)
        close(upstream)
    }

    /// With `classify`, each chunk that starts a new request is checked with
    /// isWork: the docker CLI sends HEAD /_ping first and then reuses the same
    /// keep-alive connection for the pull, push or build.
    private func copy(from src: Int32, to dst: Int32, conn: Int, classify: Bool = false) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var lastTouch = Date.distantPast
        var classify = classify
        while true {
            let n = read(src, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            if classify, Self.isWork(Self.requestLine(buf, n)) {
                lock.withLock { conns[conn]?.work = true }
                classify = false
            }
            let now = Date()
            if now.timeIntervalSince(lastTouch) >= 1 { touch(conn); lastTouch = now }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(dst, $0.baseAddress! + off, n - off) }
                if w <= 0 { shutdown(src, SHUT_RD); shutdown(dst, SHUT_WR); return }
                off += w
            }
        }
        shutdown(dst, SHUT_WR)
    }
}
