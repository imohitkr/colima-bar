import Foundation

/// Downloads `ColimaBar.zip` of one release into a folder and hashes it
/// while it writes. It stops when the file passes the size that GitHub
/// lists, follows a redirect only to a host of `ReleaseLink.downloadHosts`,
/// and never keeps a partial file that it reports as good.
///
/// `@unchecked Sendable`: `lock` guards all mutable state. The session
/// delegate queue is serial, and `cancel()` can come from any thread.
final class UpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Output: Sendable {
        let file: URL
        let bytes: Int
        /// 64 lowercase hex digits.
        let sha256: String
    }

    private let url: URL
    private let expectedSize: Int
    private let file: URL
    private let userAgent: String
    private let configure: @Sendable (URLSessionConfiguration) -> Void
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var digest = ReleaseDigest()
    private var failure: UpdateError?
    private var finished = false
    private var continuation: CheckedContinuation<Output, any Error>?
    private var lastReported = -1

    /// `file` is the path to write. Its folder must exist.
    /// `configure` changes the session settings. Tests use it to add a
    /// URLProtocol, so they need no network.
    init(
        url: URL, expectedSize: Int, file: URL, userAgent: String,
        configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in },
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.userAgent = userAgent
        self.configure = configure
        self.url = url
        self.expectedSize = expectedSize
        self.file = file
        self.progress = progress
    }

    /// Runs the download. Throws `UpdateError.cancelled` after `cancel()`.
    func run() async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, any Error>) in
                lock.lock()
                defer { lock.unlock() }
                if failure == .cancelled {
                    cont.resume(throwing: UpdateError.cancelled)
                    return
                }
                guard
                    FileManager.default.createFile(
                        atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                    let h = try? FileHandle(forWritingTo: file)
                else {
                    cont.resume(throwing: UpdateError.network("the file could not be created"))
                    return
                }
                handle = h
                continuation = cont
                let cfg = URLSessionConfiguration.ephemeral
                cfg.timeoutIntervalForRequest = 30
                cfg.timeoutIntervalForResource = 5 * 60
                cfg.urlCache = nil
                cfg.httpCookieStorage = nil
                cfg.waitsForConnectivity = false
                configure(cfg)
                let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
                var req = URLRequest(url: url)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let t = s.dataTask(with: req)
                session = s
                task = t
                t.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    /// The error for a failed write: a full disk, or another write problem
    /// with its reason.
    static func writeFailure(_ error: any Error) -> UpdateError {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return .notEnoughSpace }
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .notEnoughSpace
        }
        return .network("the file could not be written (\(error.localizedDescription))")
    }

    func cancel() {
        let t = lock.withLock { () -> URLSessionDataTask? in
            if failure == nil { failure = .cancelled }
            return task
        }
        t?.cancel()
    }

    // MARK: URLSession delegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let to = request.url, ReleaseLink.allowsRedirect(to: to) {
            completionHandler(request)
        } else {
            fail(.network("GitHub sent the download to a host that ColimaBar does not trust"))
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            fail(.network("GitHub answered with HTTP status \(code)"))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(expectedSize) {
            fail(.sizeMismatch)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var report: Double?
        var stop: URLSessionDataTask?
        lock.withLock {
            guard failure == nil, !finished else { return }
            digest.update(data)
            if digest.count > expectedSize {
                failure = .sizeMismatch
                stop = self.task
                return
            }
            do { try handle?.write(contentsOf: data) } catch {
                failure = Self.writeFailure(error)
                stop = self.task
                return
            }
            // At most 100 steps, so the main actor gets few updates.
            let step = digest.count * 100 / max(expectedSize, 1)
            if step != lastReported {
                lastReported = step
                report = Double(digest.count) / Double(max(expectedSize, 1))
            }
        }
        stop?.cancel()
        if let report { progress(min(report, 1)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (cont, result): (CheckedContinuation<Output, any Error>?, Result<Output, any Error>) = lock.withLock {
            guard !finished else { return (nil, .failure(UpdateError.cancelled)) }
            finished = true
            try? handle?.close()
            handle = nil
            let c = continuation
            continuation = nil
            let outcome: Result<Output, any Error>
            if let failure {
                outcome = .failure(failure)
            } else if let error {
                outcome = .failure(UpdateError.network(error.localizedDescription))
            } else {
                outcome = .success(Output(file: file, bytes: digest.count, sha256: digest.hex()))
            }
            return (c, outcome)
        }
        session.finishTasksAndInvalidate()
        if case .failure = result { try? FileManager.default.removeItem(at: file) }
        cont?.resume(with: result)
    }

    /// Records the first failure. The task ends with an error afterwards.
    private func fail(_ error: UpdateError) {
        let t = lock.withLock { () -> URLSessionDataTask? in
            if failure == nil { failure = error }
            return task
        }
        t?.cancel()
    }
}
