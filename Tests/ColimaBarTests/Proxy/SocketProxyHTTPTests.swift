import Foundation
import Testing

@testable import ColimaBar

@Suite struct SocketProxyHTTPTests {
    private func last(_ s: String) -> String {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBytes { SocketProxy.lastRequestLine($0) }
    }

    private func length(_ s: String) -> Int? {
        Array(s.utf8).withUnsafeBytes { SocketProxy.bodyLength($0) }
    }

    @Test func rawRequestLineMatchesTheArrayForm() {
        for s in ["POST /build HTTP/1.1\r\n", "GET /_ping HTTP/1.1", "Dockerfile\0", "", "GET x", "{\"a\":1}"] {
            let bytes = Array(s.utf8)
            let raw = bytes.withUnsafeBytes { SocketProxy.requestLine($0) }
            #expect(raw == SocketProxy.requestLine(bytes, bytes.count), "\(s.debugDescription)")
        }
    }

    @Test func lastRequestInTheChunkDecides() {
        let pull = "POST /v1.54/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n"
        let poll = "GET /v1.54/containers/json HTTP/1.1\r\nHost: d\r\n\r\n"
        #expect(last(pull + poll) == "GET /v1.54/containers/json HTTP/1.1")
        #expect(!SocketProxy.isWork(last(pull + poll)))
        #expect(SocketProxy.isWork(last(poll + pull)))
        // No Content-Length: no body, so the next request starts right after the head.
        #expect(last("POST /images/create HTTP/1.1\r\nHost: d\r\n\r\n" + poll) == "GET /v1.54/containers/json HTTP/1.1")
    }

    @Test func bodiesAreSkippedNotParsed() {
        let fake = "GET /x HTTP/1.1\r\n\r\n"
        let body = "\r\n\r\n" + fake
        // A body that looks like a request is skipped by its Content-Length.
        let withBody = "POST /build HTTP/1.1\r\ncontent-length: \(body.utf8.count)\r\n\r\n" + body
        #expect(last(withBody) == "POST /build HTTP/1.1")
        #expect(last(withBody + "GET /info HTTP/1.1\r\n\r\n") == "GET /info HTTP/1.1")
        // A chunked body stops the scan: the bytes after the head are body.
        #expect(last("POST /build HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + fake) == "POST /build HTTP/1.1")
        // A cut head or body bytes stop it too.
        #expect(last("POST /build HTTP/1.1\r\nHost: d\r\n\r\nDockerfile\0" + fake) == "POST /build HTTP/1.1")
        #expect(last("POST /build HTTP/1.1\r\nContent-Len") == "POST /build HTTP/1.1")
        #expect(last("POST /build HTTP/1.1\r\nContent-Length: 99999\r\n\r\n" + fake) == "POST /build HTTP/1.1")
        #expect(last("Dockerfile\0" + fake) == "")
    }

    @Test func bodyLengthReadsTheHead() {
        #expect(length("POST / HTTP/1.1\r\nHost: d\r\n\r\n") == 0)
        #expect(length("POST / HTTP/1.1\r\nContent-Length: 12\r\n\r\n") == 12)
        #expect(length("POST / HTTP/1.1\r\nCONTENT-LENGTH:7\r\n\r\n") == 7)
        #expect(length("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n") == nil)
        #expect(length("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == nil)
        #expect(length("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n") == nil)
        #expect(length("POST / HTTP/1.1\r\nX-Content-Length: 5\r\n\r\n") == 0)
    }

    @Test func onlyRealRequestsStartALine() {
        func line(_ s: String) -> String { SocketProxy.requestLine(Array(s.utf8), s.utf8.count) }
        #expect(line("GET /v1.54/containers/json HTTP/1.1\r\n") == "GET /v1.54/containers/json HTTP/1.1")
        #expect(line("OPTIONS /x HTTP/1.1\r\n") == "OPTIONS /x HTTP/1.1")
        #expect(line("Dockerfile\0\0\0") == "")
        #expect(line("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") == "")  // BuildKit's HTTP/2 preface
        #expect(line("GETX /a HTTP/1.1") == "")
        #expect(line("GET") == "")
    }

    @Test func requestLineIgnoresBodyBytes() {
        #expect(SocketProxy.requestLine(Array("POST /build HTTP/1.1\r\n".utf8), 22) == "POST /build HTTP/1.1")
        #expect(SocketProxy.requestLine([0x1f, 0x8b, 0x08], 3) == "")  // gzip body
        #expect(SocketProxy.requestLine(Array("{\"a\":1}".utf8), 7) == "")
    }

    @Test func logTargetDropsTheQuery() {
        let t = SocketProxy.logTarget(#"POST /v1.54/build?buildargs={"TOKEN":"s3cret"} HTTP/1.1"#)
        #expect(t == "POST /v1.54/build")
        #expect(SocketProxy.logTarget("GET /v1.54/containers/json HTTP/1.1") == "GET /v1.54/containers/json")
        #expect(SocketProxy.logTarget("") == "")
    }

    @Test func buildsPullsPushesCount() {
        #expect(SocketProxy.isWork("POST /v1.54/build?t=app HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/images/create?fromImage=alpine HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/images/registry.io/app:1/push HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/images/load HTTP/1.1"))
        #expect(SocketProxy.isWork("GET /v1.54/images/get?names=a HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /session HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /v1.54/grpc HTTP/1.1"))
        #expect(SocketProxy.isWork("POST /commit?container=x HTTP/1.1"))
    }

    @Test func pollingAndStreamsDoNot() {
        #expect(!SocketProxy.isWork("GET /v1.54/containers/json HTTP/1.1"))
        #expect(!SocketProxy.isWork("GET /v1.54/events HTTP/1.1"))
        #expect(!SocketProxy.isWork("HEAD /_ping HTTP/1.1"))
        #expect(!SocketProxy.isWork("GET /v1.54/containers/x/logs?follow=1 HTTP/1.1"))
        #expect(!SocketProxy.isWork("POST /v1.54/containers/create HTTP/1.1"))
        #expect(!SocketProxy.isWork("garbage"))
    }

    @Test func pingReplyOnlyForPings() {
        let p = SocketProxy(upstream: TestSocketPath.unique(), path: TestSocketPath.unique())
        #expect(p.pingReply("HEAD /_ping HTTP/1.1") == nil)  // API version unknown yet
        p.apiVersion = "1.54"
        let head = String(decoding: p.pingReply("HEAD /_ping HTTP/1.1")!, as: UTF8.self)
        #expect(head.contains("Api-Version: 1.54"))
        #expect(!head.hasSuffix("OK"))
        #expect(String(decoding: p.pingReply("GET /v1.54/_ping HTTP/1.1")!, as: UTF8.self).hasSuffix("\r\n\r\nOK"))
        #expect(p.pingReply("GET /v1.54/containers/json HTTP/1.1") == nil)
        #expect(p.pingReply("POST /_ping HTTP/1.1") == nil)
        #expect(p.pingReply("GET /vX/_ping HTTP/1.1") == nil)
    }
}
