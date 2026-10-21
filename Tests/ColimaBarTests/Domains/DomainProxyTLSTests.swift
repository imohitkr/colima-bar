import Foundation
import Network
import Security
import Testing

@testable import ColimaBar

/// The HTTPS listener on loopback ports that the test picks. The CA is a test
/// CA that nothing trusts: each client checks the chain with it as the only
/// anchor. No test touches a keychain of the user or a trust setting. It never
/// binds 80, 443, 8080 or 8443.
@Suite struct DomainProxyTLSTests {
    enum ProviderKind: CaseIterable, Sendable, CustomTestStringConvertible {
        case fileKeychain
        case privateAPI
        var testDescription: String { self == .fileKeychain ? "file keychain" : "private API" }
    }

    /// Owns what a test starts, so that `close()` stops it and deletes the temporary keychain.
    private final class Rig: @unchecked Sendable {
        let proxy: DomainProxy
        let ca: LocalCA
        let cache: LeafCache
        let provider: TLSIdentityProvider
        let temp: TempFolder
        let port: Int
        let httpPort: Int

        init(
            kind: ProviderKind, mode: DomainTLSServer.Mode = .perSNI, names: [String] = [],
            suffixes: [String] = ["localhost"]
        ) async throws {
            temp = try TempFolder()
            ca = try LocalCA.create(permitted: suffixes)
            switch kind {
            case .fileKeychain:
                provider = try #require(FileKeychainIdentityProvider(cacheDir: temp.path))
            case .privateAPI:
                provider = PrivateIdentityProvider()
            }
            cache = LeafCache(ca: ca, provider: provider, suffixes: suffixes)
            proxy = DomainProxy(addresses: ["127.0.0.1"])
            let server = DomainTLSServer(cache: cache, mode: mode, names: names)
            let queue = DispatchQueue(label: "test.mint")
            let candidates = try [UInt16(LoopbackListener.unusedPort())]
            port = Int(
                try #require(await proxy.startHTTPS(candidates: candidates) { server.options(mintQueue: queue) }))
            httpPort = Int(try #require(await proxy.start(candidates: [UInt16(try LoopbackListener.unusedPort())])))
        }

        func close() {
            proxy.stop()
            provider.removeAll()
        }
    }

    private func routes(_ upstreams: [String: Int], containerPort: Int = 80) -> DomainRoutes {
        let list = upstreams.map {
            DomainCandidate(
                id: $0.key, name: $0.key,
                ports: [.init(containerPort: containerPort, hostPort: $0.value, ipv6Only: false)])
        }
        return DomainRoutes.build(list, suffixes: ["localhost"], profile: "default", vmRunning: true)
    }

    private func get(_ host: String, _ path: String = "/") -> String {
        "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
    }

    @Test(arguments: ProviderKind.allCases)
    func theHostPicksTheUpstreamOverTLS(kind: ProviderKind) async throws {
        let rig = try await Rig(kind: kind)
        defer { rig.close() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        rig.proxy.routes = routes(["web": alpha.port])
        let r = await TLSClient.exchange(
            port: rig.port, sni: "web.localhost", anchor: rig.ca.certificate, send: get("web.localhost", "/x"),
            until: "/x")
        #expect(r.connected)
        #expect(r.text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(r.text.contains("alpha-server web.localhost /x"))
        #expect(r.leafName == "web.localhost")
    }

    @Test func eachNameGetsItsOwnLeafAndAHandshakeUsesTheCache() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        rig.proxy.routes = routes(["web": alpha.port, "api": alpha.port])
        for (sni, expected) in [("web.localhost", 1), ("api.localhost", 2), ("web.localhost", 2)] {
            let r = await TLSClient.exchange(
                port: rig.port, sni: sni, anchor: rig.ca.certificate, send: get(sni), until: "alpha-server")
            #expect(r.leafName == sni)
            #expect(rig.cache.mintedCount == expected)
        }
    }

    @Test func aNameOutsideTheSuffixGetsTheLocalhostLeaf() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let seen = await TLSClient.exchange(
            port: rig.port, sni: "www.example.com", anchor: nil, send: get("www.example.com"), until: "</html>")
        #expect(seen.leafName == "localhost")
        // With the chain check, the client rejects that certificate for that name.
        let strict = await TLSClient.exchange(
            port: rig.port, sni: "www.example.com", anchor: rig.ca.certificate, send: get("www.example.com"),
            until: "</html>")
        #expect(!strict.connected)
        let none = await TLSClient.exchange(
            port: rig.port, sni: nil, anchor: nil, send: get("localhost"), until: "</html>")
        #expect(none.leafName == "localhost")
        #expect(rig.cache.mintedCount == 1)
    }

    @Test(arguments: ProviderKind.allCases)
    func oneCertificateServesEveryNameInTheFallbackMode(kind: ProviderKind) async throws {
        let names = ["web.localhost", "api.localhost", "localhost"]
        let rig = try await Rig(kind: kind, mode: .multiSAN, names: names)
        defer { rig.close() }
        for sni in names {
            let r = await TLSClient.exchange(
                port: rig.port, sni: sni, anchor: rig.ca.certificate, send: get(sni), until: "</html>")
            #expect(r.connected, "\(sni)")
            #expect(r.leafName != nil)
        }
        #expect(rig.cache.mintedCount == 1)
    }

    @Test func theSelfTestPassesWithTheRightCAAndFailsOtherwise() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        rig.proxy.routes = routes([:])
        #expect(await DomainTLSServer.selfTest(port: UInt16(rig.port), ca: rig.ca))
        let other = try LocalCA.create(permitted: ["localhost"])
        #expect(await !DomainTLSServer.selfTest(port: UInt16(rig.port), ca: other, timeout: 3))
        // Nothing listens on this port.
        #expect(
            await !DomainTLSServer.selfTest(port: UInt16(try LoopbackListener.unusedPort()), ca: rig.ca, timeout: 3))
    }

    @Test func theSelfTestPassesWhileTheVMIsStopped() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        rig.proxy.routes = DomainRoutes.build([], suffixes: ["localhost"], profile: "default", vmRunning: false)
        #expect(await DomainTLSServer.selfTest(port: UInt16(rig.port), ca: rig.ca))
    }

    @Test func theConnectionNegotiatesHTTP11EvenIfTheClientOffersHTTP2() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let r = await TLSClient.exchange(
            port: rig.port, sni: "web.localhost", anchor: rig.ca.certificate, alpns: ["h2", "http/1.1"],
            send: get("web.localhost"), until: "</html>")
        #expect(r.connected)
        #expect(r.alpn == "http/1.1")
        let only = await TLSClient.exchange(
            port: rig.port, sni: "web.localhost", anchor: rig.ca.certificate, alpns: ["h2"],
            send: get("web.localhost"), until: "</html>")
        #expect(only.alpn != "h2")
    }

    @Test func anUnknownNameGetsAPageWithHTTPSLinks() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        rig.proxy.routes = routes(["web": alpha.port])
        let r = await TLSClient.exchange(
            port: rig.port, sni: "nope.localhost", anchor: rig.ca.certificate, send: get("nope.localhost"),
            until: "</html>")
        #expect(r.text.hasPrefix("HTTP/1.1 404"))
        #expect(r.text.contains("href=\"https://web.localhost:\(rig.port)/\""))
        let http = await tcpExchange(port: rig.httpPort, send: [httpGet("nope.localhost")], until: "</html>")
        #expect(http.contains("href=\"http://web.localhost:\(rig.httpPort)/\""))
    }

    @Test func aRouteToAContainerPort443UsesTLSToTheUpstream() async throws {
        let upstream = try #require(await TLSUpstream.start())
        defer { upstream.stop() }
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        rig.proxy.routes = routes(["secure": upstream.port], containerPort: 443)
        let r = await TLSClient.exchange(
            port: rig.port, sni: "secure.localhost", anchor: rig.ca.certificate, send: get("secure.localhost"),
            until: "alpn=")
        #expect(r.text.contains("tls-upstream sni=secure.localhost alpn=http/1.1"))
    }

    @Test func aRouteToTheHTTPSPortOfTheProxyIsASelfLoop() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        rig.proxy.routes = routes(["loop": rig.port])
        let r = await TLSClient.exchange(
            port: rig.port, sni: "loop.localhost", anchor: rig.ca.certificate, send: get("loop.localhost"),
            until: "</html>")
        #expect(r.text.hasPrefix("HTTP/1.1 502"))
        let viaHTTP = await tcpExchange(port: rig.httpPort, send: [httpGet("loop.localhost")], until: "</html>")
        #expect(viaHTTP.hasPrefix("HTTP/1.1 502"))
    }

    @Test func stoppingHTTPSLeavesHTTPAndTheOtherWayAround() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        rig.proxy.routes = routes(["web": alpha.port])
        #expect(rig.proxy.httpsPort == UInt16(rig.port) && rig.proxy.port == UInt16(rig.httpPort))
        rig.proxy.stopHTTPS()
        #expect(rig.proxy.httpsPort == nil && rig.proxy.port == UInt16(rig.httpPort))
        let http = await tcpExchange(port: rig.httpPort, send: [httpGet("web.localhost")], until: "alpha-server")
        #expect(http.contains("alpha-server"))
        let canConnect = await onOwnThread { [port = rig.port] in TCPClient(port: port) != nil }
        #expect(!canConnect)
    }

    @Test func aNewHTTPStartLeavesHTTPSRunning() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        rig.proxy.routes = routes(["web": alpha.port])
        let next = try #require(await rig.proxy.start(candidates: [UInt16(try LoopbackListener.unusedPort())]))
        #expect(next != UInt16(rig.httpPort) && rig.proxy.httpsPort == UInt16(rig.port))
        let r = await TLSClient.exchange(
            port: rig.port, sni: "web.localhost", anchor: rig.ca.certificate, send: get("web.localhost"),
            until: "alpha-server")
        #expect(r.text.contains("alpha-server"))
    }

    @Test func stopEndsBothListeners() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        rig.proxy.stop()
        #expect(rig.proxy.httpsPort == nil && rig.proxy.port == nil)
    }

    @Test func aFailedHTTPSListenerCallsItsOwnHandlerOnly() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let https = Counter()
        let http = Counter()
        rig.proxy.onHTTPSListenerFailure = { https.add() }
        rig.proxy.onListenerFailure = { http.add() }
        rig.proxy.simulateHTTPSListenerFailure()
        #expect(https.value == 1 && http.value == 0)
        #expect(rig.proxy.httpsPort == nil && rig.proxy.port == UInt16(rig.httpPort))
    }

    @Test func plainTextOnTheTLSPortEndsTheSession() async throws {
        let rig = try await Rig(kind: .privateAPI)
        defer { rig.close() }
        let port = rig.port
        let answer = await onOwnThread {
            guard let client = TCPClient(port: port) else { return "no connection" }
            client.send(Data("GET / HTTP/1.1\r\nHost: a.localhost\r\n\r\n".utf8))
            return client.read(timeout: 5)
        }
        #expect(!answer.contains("HTTP/1.1 200"))
        #expect(await waitUntil { rig.proxy.sessionCount == 0 })
    }

    @Test func aHandshakeThatNeverEndsIsClosedAtTheHeadTimeout() async throws {
        let ca = try LocalCA.create(permitted: ["localhost"])
        let cache = LeafCache(ca: ca, provider: PrivateIdentityProvider(), suffixes: ["localhost"])
        var limits = DomainProxy.Limits()
        limits.headTimeout = 0.3
        let proxy = DomainProxy(addresses: ["127.0.0.1"], limits: limits)
        defer { proxy.stop() }
        let server = DomainTLSServer(cache: cache, mode: .perSNI)
        let queue = DispatchQueue(label: "test.mint")
        let port = try #require(
            await proxy.startHTTPS(candidates: [UInt16(try LoopbackListener.unusedPort())]) {
                server.options(mintQueue: queue)
            })
        let silent = await onOwnThread {
            // Connects and says nothing: the TLS handshake never starts.
            let client = TCPClient(port: Int(port))
            _ = client?.read(timeout: 5)
            return client != nil
        }
        #expect(silent)
        #expect(await waitUntil { proxy.sessionCount == 0 })
    }
}
