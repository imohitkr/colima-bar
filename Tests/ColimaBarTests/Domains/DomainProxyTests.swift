import Foundation
import Network
import Testing

@testable import ColimaBar

/// The proxy on loopback ports that the test picks. It never binds 80, 443 or 8080.
@Suite struct DomainProxyTests {
    private typealias Rig = (proxy: DomainProxy, port: Int)

    private func started(limits: DomainProxy.Limits = .init()) async throws -> Rig {
        let proxy = DomainProxy(addresses: ["127.0.0.1"], limits: limits)
        let candidates = try [LoopbackListener.unusedPort(), LoopbackListener.unusedPort()].map { UInt16($0) }
        let port = try #require(await proxy.start(candidates: candidates))
        return (proxy, Int(port))
    }

    /// Routes `<name>.localhost` to the upstream ports.
    private func routes(_ upstreams: [String: Int], vmRunning: Bool = true) -> DomainRoutes {
        let list = upstreams.map {
            DomainCandidate(
                id: $0.key, name: $0.key, ports: [.init(containerPort: 80, hostPort: $0.value)])
        }
        return DomainRoutes.build(list, suffixes: ["localhost"], profile: "default", vmRunning: vmRunning)
    }

    private func canConnect(_ port: Int) async -> Bool {
        await onOwnThread { TCPClient(port: port) != nil }
    }

    /// True once nothing accepts on the port. A cancelled listener closes a moment later.
    private func refuses(_ port: Int) async -> Bool {
        for _ in 0..<500 {
            if await !canConnect(port) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func productionBindsOnlyTheLoopbackAddresses() {
        #expect(DomainProxy().addresses == ["127.0.0.1", "::1"])
        #expect(DomainProxy.loopbackAddresses == ["127.0.0.1", "::1"])
    }

    @Test func theHostPicksTheUpstream() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        let beta = try LoopbackHTTPServer(marker: "beta-server")
        proxy.routes = routes(["alpha": alpha.port, "beta": beta.port])
        let a = await tcpExchange(port: port, send: [httpGet("alpha.localhost", "/x")], until: "/x")
        #expect(a.hasPrefix("HTTP/1.1 200 OK"))
        #expect(a.contains("alpha-server alpha.localhost /x"))
        let b = await tcpExchange(port: port, send: [httpGet("Beta.Localhost:8080")], until: "/")
        #expect(b.contains("beta-server Beta.Localhost:8080 /"))
    }

    @Test func aSubdomainReachesItsParent() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        let r = await tcpExchange(port: port, send: [httpGet("api.alpha.localhost")], until: "api.alpha.localhost /")
        #expect(r.contains("alpha-server api.alpha.localhost /"))
    }

    @Test func laterRequestsOnOneConnectionGoToTheSameUpstream() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        let r = await tcpExchange(
            port: port, send: [httpGet("alpha.localhost", "/one"), httpGet("alpha.localhost", "/two")], until: "/two")
        #expect(r.contains("alpha-server alpha.localhost /one"))
        #expect(r.contains("alpha-server alpha.localhost /two"))
        #expect(alpha.requestCount == 2)
    }

    @Test func anUnknownNameGetsANotFoundPageWithTheList() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        let r = await tcpExchange(port: port, send: [httpGet("nope.localhost")], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 404 Not Found"))
        #expect(r.contains("No container at nope.localhost"))
        // The port is not 80, so the link has it.
        #expect(r.contains("alpha.localhost:\(port)"))
        #expect(alpha.requestCount == 0)
    }

    @Test func aForeignHostGetsNoList() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        for host in ["evil.com", "127.0.0.1", "[::1]:80"] {
            let r = await tcpExchange(port: port, send: [httpGet(host)], until: "</html>")
            #expect(r.hasPrefix("HTTP/1.1 404 Not Found"), "\(host)")
            #expect(r.contains("Unknown address"), "\(host)")
            #expect(!r.contains("alpha"), "\(host)")
        }
        #expect(alpha.requestCount == 0)
    }

    @Test func aHeadRequestToAnUnknownNameGetsNoBody() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        proxy.routes = routes([:])
        let r = await tcpExchange(
            port: port, send: [Data("HEAD / HTTP/1.1\r\nHost: nope.localhost\r\n\r\n".utf8)])
        #expect(r.hasPrefix("HTTP/1.1 404 Not Found"))
        #expect(r.contains("Content-Length:"))
        #expect(!r.contains("<html"))
    }

    @Test func aMissingHostGetsABadRequest() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let r = await tcpExchange(port: port, send: [Data("GET / HTTP/1.1\r\n\r\n".utf8)])
        #expect(r.hasPrefix("HTTP/1.1 400 Bad Request"))
        let h2 = await tcpExchange(port: port, send: [Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)])
        #expect(h2.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    @Test func anUpstreamThatDoesNotAnswerGetsABadGatewayPage() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let dead = try LoopbackListener.unusedPort()
        proxy.routes = routes(["alpha": dead])
        let r = await tcpExchange(port: port, send: [httpGet("alpha.localhost")], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 502 Bad Gateway"))
        #expect(r.contains("alpha.localhost points to the container alpha on port 80 (localhost:\(dead))"))
    }

    @Test func aStoppedVMGetsAServiceUnavailablePage() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port], vmRunning: false)
        let r = await tcpExchange(port: port, send: [httpGet("alpha.localhost")], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 503 Service Unavailable"))
        #expect(r.contains("Colima profile default is not running."))
        #expect(alpha.requestCount == 0)
    }

    @Test func aHeadOf64KBWithNoEndGetsRequestHeaderFieldsTooLarge() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        // Exactly the limit: the proxy has read every byte when it answers.
        let start = "GET / HTTP/1.1\r\nHost: alpha.localhost\r\nX: "
        let filler = String(repeating: "x", count: HTTPHead.maxBytes - start.utf8.count)
        let r = await tcpExchange(port: port, send: [Data((start + filler).utf8)], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 431 Request Header Fields Too Large"))
    }

    @Test func aSlowHeadGetsARequestTimeout() async throws {
        var limits = DomainProxy.Limits()
        limits.headTimeout = 0.3
        let (proxy, port) = try await started(limits: limits)
        defer { proxy.stop() }
        let r = await tcpExchange(port: port, send: [Data("GET / HTTP/1.1\r\n".utf8)], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 408 Request Timeout"))
        #expect(await waitUntil { proxy.sessionCount == 0 })
    }

    @Test func aBusyPortMakesStartTakeTheNextCandidate() async throws {
        let held = try LoopbackListener(.quiet)
        let free = try LoopbackListener.unusedPort()
        let proxy = DomainProxy(addresses: ["127.0.0.1"])
        defer { proxy.stop() }
        let port = await proxy.start(candidates: [UInt16(held.port), UInt16(free)])
        #expect(port == UInt16(free))
        #expect(proxy.port == UInt16(free))
    }

    @Test func startReturnsNilWhenEveryCandidateIsBusy() async throws {
        let held = try LoopbackListener(.quiet)
        let proxy = DomainProxy(addresses: ["127.0.0.1"])
        defer { proxy.stop() }
        #expect(await proxy.start(candidates: [UInt16(held.port)]) == nil)
        #expect(proxy.port == nil)
        #expect(await proxy.start(candidates: []) == nil)
    }

    @Test func aSecondStartReplacesTheFirstListener() async throws {
        let (proxy, first) = try await started()
        defer { proxy.stop() }
        let next = try LoopbackListener.unusedPort()
        #expect(await proxy.start(candidates: [UInt16(next)]) == UInt16(next))
        #expect(proxy.port == UInt16(next))
        #expect(await refuses(first))
        #expect(await canConnect(next))
    }

    @Test func stopClosesTheListenerAndTheSessions() async throws {
        let (proxy, port) = try await started()
        let alpha = try LoopbackHTTPServer(marker: "alpha-server", mode: .echo)
        proxy.routes = routes(["alpha": alpha.port])
        let open = await onOwnThread { () -> Bool in
            guard let client = TCPClient(port: port) else { return false }
            client.send(httpGet("alpha.localhost"))
            _ = client.read(until: "\r\n\r\n", timeout: 10)
            return true
        }
        #expect(open)
        proxy.stop()
        #expect(proxy.port == nil)
        #expect(proxy.sessionCount == 0)
        #expect(await refuses(port))
    }

    @Test func aRouteSwapAppliesToNewConnections() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        let beta = try LoopbackHTTPServer(marker: "beta-server")
        proxy.routes = routes(["web": alpha.port])
        let before = await tcpExchange(port: port, send: [httpGet("web.localhost")], until: "web.localhost /")
        #expect(before.contains("alpha-server"))
        proxy.routes = routes(["web": beta.port])
        let after = await tcpExchange(port: port, send: [httpGet("web.localhost")], until: "web.localhost /")
        #expect(after.contains("beta-server"))
    }

    @Test func tooManySessionsGetAServiceUnavailablePage() async throws {
        var limits = DomainProxy.Limits()
        limits.maxSessions = 1
        let (proxy, port) = try await started(limits: limits)
        defer { proxy.stop() }
        let holder = await onOwnThread { TCPClient(port: port) }
        #expect(holder != nil)
        #expect(await waitUntil { proxy.sessionCount == 1 })
        let r = await tcpExchange(port: port, send: [], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 503 Service Unavailable"))
        #expect(r.contains("Too many connections"))
        #expect(proxy.sessionCount == 1)
        _ = holder
    }

    @Test func aSessionEndsWhenTheClientCloses() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        _ = await tcpExchange(port: port, send: [httpGet("alpha.localhost")], until: "alpha.localhost /")
        #expect(await waitUntil { proxy.sessionCount == 0 })
    }

    @Test func bytesAfterTheHeadFlowBothWays() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let echo = try LoopbackHTTPServer(marker: "echo-server", mode: .echo)
        proxy.routes = routes(["ws": echo.port])
        let result = await onOwnThread { () -> [String] in
            guard let client = TCPClient(port: port) else { return ["<no connect>"] }
            client.send(httpGet("ws.localhost"))
            let head = client.read(until: "\r\n\r\n", timeout: 10)
            client.send(Data("ping-one".utf8))
            let first = client.read(until: "ping-one", timeout: 10)
            client.send(Data("ping-two".utf8))
            let second = client.read(until: "ping-two", timeout: 10)
            return [head, first, second]
        }
        #expect(result.first?.hasPrefix("HTTP/1.1 200 OK") == true)
        #expect(result.dropFirst().first == "ping-one")
        #expect(result.last == "ping-two")
    }

    @Test func aHalfCloseReachesTheUpstream() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let echo = try LoopbackHTTPServer(marker: "echo-server", mode: .echo)
        proxy.routes = routes(["ws": echo.port])
        let reply = await tcpExchange(port: port, send: [httpGet("ws.localhost")], until: "\r\n\r\n", halfClose: true)
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"), "[\(reply)]")
        #expect(await waitUntil { echo.endsOfStream == 1 })
        #expect(await waitUntil { proxy.sessionCount == 0 })
    }

    @Test func routesToTLSPortsGetTLSParameters() {
        func hasTLS(_ p: NWParameters) -> Bool {
            p.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options }
        }
        #expect(hasTLS(DomainSession.upstreamParameters(tls: true, host: "web.localhost")))
        #expect(!hasTLS(DomainSession.upstreamParameters(tls: false, host: "web.localhost")))
    }
}
