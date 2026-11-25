import Foundation
import Testing

@testable import ColimaBar

@Suite struct BindRewriteStreamTests {
    private static let body = #"{"Image":"alpine","HostConfig":{"Binds":["/tmp/x/file.py:/app/file.py"]}}"#

    private static func create(_ path: String = "/v1.54/containers/create", body: String = body, extra: String = "")
        -> String
    {
        "POST \(path) HTTP/1.1\r\nHost: api.moby.localhost\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private static let ping = "HEAD /_ping HTTP/1.1\r\nHost: api.moby.localhost\r\n\r\n"

    /// The output of a stream and how often it asked if `/private/tmp` is shared.
    private struct Run {
        var out = ""
        var asks = 0
        var isRaw = false
    }

    /// Feeds the chunks to a new stream, then finishes it.
    private func run(_ chunks: [String], shared: Bool = true, finish: Bool = true) -> Run {
        let asks = Counter()
        let stream = BindRewriteStream {
            asks.add()
            return shared
        }
        var out = Data()
        let emit: (UnsafeRawBufferPointer) -> Bool = {
            out.append(contentsOf: $0)
            return true
        }
        for chunk in chunks {
            #expect(Array(chunk.utf8).withUnsafeBytes { stream.feed($0, emit: emit) })
        }
        let raw = stream.isRaw
        if finish { #expect(stream.finish(emit: emit)) }
        return Run(out: String(decoding: out, as: UTF8.self), asks: asks.value, isRaw: raw)
    }

    /// The request that a rewrite gives for `create(path)`.
    private func rewritten(_ path: String = "/v1.54/containers/create") throws -> String {
        let request = Data(Self.create(path).utf8)
        let split = try #require(request.range(of: Data("\r\n\r\n".utf8)))
        let out = try #require(
            BindPathRewrite.rewrittenRequest(head: request[..<split.upperBound], body: request[split.upperBound...]))
        return String(decoding: out, as: UTF8.self)
    }

    /// Every way to cut `s` into two chunks, and one chunk for each byte.
    private func cuts(_ s: String) -> [[String]] {
        let bytes = Array(s.utf8)
        let halves = (1..<bytes.count).map {
            [String(decoding: bytes[..<$0], as: UTF8.self), String(decoding: bytes[$0...], as: UTF8.self)]
        }
        return halves + [bytes.map { String(decoding: [$0], as: UTF8.self) }]
    }

    @Test func rewritesACreateRequest() throws {
        for path in ["/v1.54/containers/create", "/containers/create", "/v1.54/containers/create?name=web"] {
            let r = run([Self.create(path)])
            #expect(r.out == (try rewritten(path)))
            #expect(r.out.contains("/private/tmp/x/file.py:/app/file.py"))
            #expect(r.asks == 1)
            #expect(!r.isRaw)
        }
    }

    @Test func rewritesWhateverTheChunksAre() throws {
        let want = try rewritten()
        for chunks in cuts(Self.ping + Self.create()) {
            #expect(run(chunks).out == Self.ping + want)
        }
    }

    @Test func passesTheRequestWhenTheVMDoesNotShareTmp() {
        let r = run([Self.create()], shared: false)
        #expect(r.out == Self.create())
        #expect(r.asks == 1)
    }

    @Test func asksOnlyForATmpBind() {
        let body = #"{"Image":"alpine","HostConfig":{"Binds":["/Users/me/code:/code"]}}"#
        let r = run([Self.create(body: body)])
        #expect(r.out == Self.create(body: body))
        #expect(r.asks == 0)
    }

    @Test func passesInvalidJSON() {
        let body = #"{"HostConfig":{"Binds":["/tmp/x:/x"]"#
        let r = run([Self.create(body: body)])
        #expect(r.out == Self.create(body: body))
        #expect(r.asks == 0)
    }

    @Test func leavesOtherRequestsAlone() {
        let start =
            "POST /v1.54/containers/abc/start HTTP/1.1\r\nContent-Length: \(Self.body.utf8.count)\r\n\r\n\(Self.body)"
        let list = "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n"
        let r = run([start + list])
        #expect(r.out == start + list)
        #expect(r.asks == 0)
        #expect(!r.isRaw)
    }

    @Test func keepsFollowingRequestsAfterACreate() throws {
        let list = "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n"
        let r = run([Self.create() + list + Self.create()])
        let want = try rewritten()
        #expect(r.out == want + list + want)
        #expect(r.asks == 2)
    }

    @Test func passesEverythingAfterAnAttach() {
        let attach =
            "POST /v1.54/containers/abc/attach?stream=1&stdin=1 HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
        // Raw stdin that looks like a create request must not change.
        let r = run([attach, Self.create()])
        #expect(r.out == attach + Self.create())
        #expect(r.isRaw)
        #expect(r.asks == 0)
    }

    @Test func passesEverythingAfterARequestThatCanSwitchToAStream() {
        let heads = [
            "POST /v1.54/exec/abc/start HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",
            "POST /containers/abc/attach HTTP/1.1\r\n\r\n",
            "GET /v1.54/containers/abc/attach/ws HTTP/1.1\r\n\r\n",
            "POST /session HTTP/1.1\r\n\r\n",
            "POST /grpc HTTP/1.1\r\n\r\n",
            "GET /v1.54/events HTTP/1.1\r\nUpgrade: h2c\r\n\r\n",
        ]
        for head in heads {
            let r = run([head + Self.create()])
            #expect(r.out == head + Self.create())
            #expect(r.isRaw, "\(head.debugDescription)")
        }
    }

    @Test func passesAChunkedBody() {
        let chunked =
            "POST /v1.54/containers/create HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "\(String(Self.body.utf8.count, radix: 16))\r\n\(Self.body)\r\n0\r\n\r\n"
        let r = run([chunked])
        #expect(r.out == chunked)
        #expect(r.isRaw)
    }

    @Test func doesNotHoldABodyThatWaitsForContinue() {
        let request = Self.create(extra: "Expect: 100-continue\r\n")
        let split = request.range(of: "\r\n\r\n")!.upperBound
        let head = String(request[..<split])
        let r = run([head], finish: false)
        #expect(r.out == head)
        #expect(run([request]).out == request)
    }

    @Test func passesALargeBody() {
        let pad = String(repeating: "a", count: BindPathRewrite.maxBody)
        let body = #"{"Labels":{"pad":"\#(pad)"},"HostConfig":{"Binds":["/tmp/x:/x"]}}"#
        let r = run([Self.create(body: body)])
        #expect(r.out == Self.create(body: body))
        #expect(r.asks == 0)
    }

    @Test func passesBytesThatAreNotHTTP() {
        let preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        let r = run([preface + Self.create()])
        #expect(r.out == preface + Self.create())
        #expect(r.isRaw)
    }

    @Test func finishSendsAHeldPartialRequest() {
        let partial = String(Self.create().dropLast(5))
        let held = run([partial], finish: false)
        #expect(held.out.isEmpty)
        #expect(run([partial]).out == partial)
    }

    @Test func stopsWhenTheDaemonSideFails() {
        let stream = BindRewriteStream { true }
        let ok = Array(Self.create().utf8).withUnsafeBytes { stream.feed($0) { _ in false } }
        #expect(!ok)
    }
}
