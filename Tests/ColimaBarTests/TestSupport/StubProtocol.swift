import Foundation

/// A URLProtocol that answers requests from a table, so download tests need
/// no network. Register a answer for a URL that no other test uses (put a
/// UUID in the path): suites run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case body(status: Int, chunks: [Data])
        case redirect(to: URL)
        /// A 200 answer without a Content-Length header.
        case unsizedBody(chunks: [Data])
        /// A 200 answer with one chunk, then no end (a stalled transfer).
        case stall(first: Data)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]

    static func register(_ url: URL, _ answer: Answer) {
        lock.withLock { answers[url.absoluteString] = answer }
    }

    /// The configuration hook for UpdateDownload.
    static let useIt: @Sendable (URLSessionConfiguration) -> Void = { cfg in
        cfg.protocolClasses = [StubProtocol.self]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let answer = Self.lock.withLock({ Self.answers[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        switch answer {
        case .redirect(let to):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": to.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: response)
        case .unsizedBody(let chunks):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: c) }
            client?.urlProtocolDidFinishLoading(self)
        case .stall(let first):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: first)
        case .body(let status, let chunks):
            let total = chunks.reduce(0) { $0 + $1.count }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "\(total)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: c) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
