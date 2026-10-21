import Foundation
import Network
import Testing

@testable import ColimaBar

/// The proxy on loopback ports that the test picks. It never binds 80, 443 or 8080.
@Suite struct DomainProxyTests {
    private typealias Rig = (proxy: DomainProxy, port: Int)

    private func started(
        limits: DomainProxy.Limits = .init(), addresses: [String] = ["127.0.0.1"], unchecked: Bool = false
    ) async throws -> Rig {
        let proxy =
            unchecked
            ? DomainProxy(unchecked: addresses, limits: limits) : DomainProxy(addresses: addresses, limits: limits)
        let candidates = try [LoopbackListener.unusedPort(), LoopbackListener.unusedPort()].map { UInt16($0) }
        let port = try #require(await proxy.start(candidates: candidates))
        return (proxy, Int(port))
    }

    /// Routes `<name>.localhost` to the upstream ports.
    private func routes(
        _ upstreams: [String: Int], vmRunning: Bool = true, containerPort: Int = 80, ipv6Only: Bool = false
    ) -> DomainRoutes {
        let list = upstreams.map {
            DomainCandidate(
                id: $0.key, name: $0.key,
                ports: [.init(containerPort: containerPort, hostPort: $0.value, ipv6Only: ipv6Only)])
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

    // MARK: Guards and pages

    @Test func aRouteToThePortOfTheProxyGetsABadGatewayPage() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        proxy.routes = routes(["loop": port])
        let r = await tcpExchange(port: port, send: [httpGet("loop.localhost")], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 502 Bad Gateway"))
        #expect(r.contains("That is the port of this proxy."))
        // The proxy did not dial itself: no second session stays open.
        #expect(await waitUntil { proxy.sessionCount == 0 })
    }

    @Test func anAbsoluteTargetThatDiffersFromTheHostGetsABadRequest() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        let request = Data("GET http://alpha.localhost/ HTTP/1.1\r\nHost: evil.com\r\n\r\n".utf8)
        let r = await tcpExchange(port: port, send: [request], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 400 Bad Request"))
        #expect(alpha.requestCount == 0)
    }

    @Test func aHeadRequestGetsNoBodyFromABadGatewayOrAStoppedVM() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let head = Data("HEAD / HTTP/1.1\r\nHost: alpha.localhost\r\n\r\n".utf8)
        proxy.routes = routes(["alpha": try LoopbackListener.unusedPort()])
        let bad = await tcpExchange(port: port, send: [head])
        #expect(bad.hasPrefix("HTTP/1.1 502 Bad Gateway"))
        #expect(bad.contains("Content-Length:"))
        #expect(!bad.contains("<html"))
        proxy.routes = routes(["alpha": 1], vmRunning: false)
        let stopped = await tcpExchange(port: port, send: [head])
        #expect(stopped.hasPrefix("HTTP/1.1 503 Service Unavailable"))
        #expect(!stopped.contains("<html"))
    }

    @Test func anErrorPageReachesAClientThatSendsABodyAfterTheHead() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let junk = Data(repeating: 0x41, count: 300_000)
        let r = await onOwnThread { () -> String in
            guard let client = TCPClient(port: port) else { return "<no connect>" }
            client.send(Data("GET / HTTP/1.1\r\n\r\n".utf8))
            client.send(junk)
            return client.read(until: "</html>", timeout: 10)
        }
        #expect(r.hasPrefix("HTTP/1.1 400 Bad Request"), "[\(r.prefix(40))]")
        #expect(r.contains("</html>"))
    }

    // MARK: Lifecycle

    @Test func stopEndsTheConnectionOfTheClient() async throws {
        let (proxy, port) = try await started()
        let echo = try LoopbackHTTPServer(marker: "echo-server", mode: .echo)
        proxy.routes = routes(["ws": echo.port])
        let client = await onOwnThread { () -> TCPClient? in
            guard let client = TCPClient(port: port) else { return nil }
            client.send(httpGet("ws.localhost"))
            _ = client.read(until: "\r\n\r\n", timeout: 10)
            return client
        }
        let open = try #require(client)
        proxy.stop()
        // The read ends with the end of the stream, long before its 10 s limit.
        let started = Date()
        let rest = await onOwnThread { open.read(until: nil, timeout: 10) }
        #expect(rest.isEmpty)
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func aRouteSwapKeepsASplicedUpstream() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let echo = try LoopbackHTTPServer(marker: "echo-server", mode: .echo)
        let other = try LoopbackHTTPServer(marker: "other-server")
        proxy.routes = routes(["ws": echo.port])
        let client = await onOwnThread { () -> TCPClient? in
            guard let client = TCPClient(port: port) else { return nil }
            client.send(httpGet("ws.localhost"))
            _ = client.read(until: "\r\n\r\n", timeout: 10)
            return client
        }
        let open = try #require(client)
        proxy.routes = routes(["ws": other.port])
        let reply = await onOwnThread { () -> String in
            open.send(Data("after-swap".utf8))
            return open.read(until: "after-swap", timeout: 10)
        }
        #expect(reply == "after-swap")
        #expect(other.requestCount == 0)
    }

    @Test func aQuickRestartOnTheSamePortBinds() async throws {
        let proxy = DomainProxy(addresses: ["127.0.0.1"])
        defer { proxy.stop() }
        let port = UInt16(try LoopbackListener.unusedPort())
        #expect(await proxy.start(candidates: [port]) == port)
        #expect(await proxy.start(candidates: [port]) == port)
        #expect(await proxy.start(candidates: [port]) == port)
        #expect(await canConnect(Int(port)))
    }

    @Test func aStartRightAfterAStopReusesThePort() async throws {
        let proxy = DomainProxy(addresses: ["127.0.0.1"])
        defer { proxy.stop() }
        let port = UInt16(try LoopbackListener.unusedPort())
        for _ in 0..<5 {
            #expect(await proxy.start(candidates: [port, UInt16(try LoopbackListener.unusedPort())]) == port)
            proxy.stop()
        }
        #expect(await proxy.start(candidates: [port]) == port)
        #expect(await canConnect(Int(port)))
    }

    @Test func twoStartsAtOnceLeaveOneListener() async throws {
        let proxy = DomainProxy(addresses: ["127.0.0.1"])
        defer { proxy.stop() }
        let one = UInt16(try LoopbackListener.unusedPort())
        let two = UInt16(try LoopbackListener.unusedPort())
        async let a = proxy.start(candidates: [one])
        async let b = proxy.start(candidates: [two])
        _ = await (a, b)
        let bound = try #require(proxy.port)
        #expect(await canConnect(Int(bound)))
        // The start that lost left no listener on its port.
        let other = bound == one ? two : one
        #expect(await refuses(Int(other)))
        proxy.stop()
        #expect(await refuses(Int(bound)))
    }

    @Test func aStopWhileAStartRunsLeavesNothingBound() async throws {
        let proxy = DomainProxy(addresses: ["127.0.0.1"])
        let port = UInt16(try LoopbackListener.unusedPort())
        async let started = proxy.start(candidates: [port])
        proxy.stop()
        _ = await started
        proxy.stop()
        #expect(proxy.port == nil)
        #expect(await refuses(Int(port)))
    }

    @Test func aBusyPageEndsWithTheClientAndWithStop() async throws {
        var limits = DomainProxy.Limits()
        limits.maxSessions = 1
        let (proxy, port) = try await started(limits: limits)
        let holder = await onOwnThread { TCPClient(port: port) }
        #expect(holder != nil)
        #expect(await waitUntil { proxy.sessionCount == 1 })
        _ = await tcpExchange(port: port, send: [], until: "</html>")
        #expect(await waitUntil { proxy.rejectCount == 0 })
        // A rejected client that stays open is cancelled by stop().
        let open = await onOwnThread { () -> TCPClient? in
            guard let client = TCPClient(port: port) else { return nil }
            _ = client.read(until: "</html>", timeout: 10)
            return client
        }
        #expect(open != nil)
        proxy.stop()
        #expect(proxy.rejectCount == 0)
        _ = holder
    }

    @Test func aListenerFailureStopsTheProxyAndCallsTheHandler() async throws {
        let (proxy, port) = try await started()
        let called = Counter()
        proxy.onListenerFailure = { called.add() }
        proxy.simulateListenerFailure()
        #expect(called.value == 1)
        #expect(proxy.port == nil)
        #expect(await refuses(port))
    }

    // MARK: Addresses

    @Test func theProxyServesIPv4AndIPv6() async throws {
        let (proxy, port) = try await started(addresses: DomainProxy.loopbackAddresses)
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        let v4 = await tcpExchange(port: port, send: [httpGet("alpha.localhost")], until: "alpha.localhost /")
        let v6 = await tcpExchange(
            port: port, ipv6: true, send: [httpGet("alpha.localhost", "/six")], until: "/six")
        #expect(v4.contains("alpha-server alpha.localhost /"))
        #expect(v6.contains("alpha-server alpha.localhost /six"))
    }

    @Test func aMissingIPv6AddressStillServesIPv4() async throws {
        // 2001:db8::1 is a documentation address that no interface has.
        let (proxy, port) = try await started(addresses: ["127.0.0.1", "2001:db8::1"], unchecked: true)
        defer { proxy.stop() }
        let alpha = try LoopbackHTTPServer(marker: "alpha-server")
        proxy.routes = routes(["alpha": alpha.port])
        let r = await tcpExchange(port: port, send: [httpGet("alpha.localhost")], until: "alpha.localhost /")
        #expect(r.contains("alpha-server alpha.localhost /"))
    }

    @Test func aPortThatOnlyIPv6PublishesIsDialedOnIPv6() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let six = try LoopbackHTTPServer(marker: "six-server", ipv6: true)
        let four = try LoopbackHTTPServer(marker: "four-server")
        proxy.routes = routes(["six": six.port], ipv6Only: true)
        let r = await tcpExchange(port: port, send: [httpGet("six.localhost")], until: "six.localhost /")
        #expect(r.contains("six-server six.localhost /"))
        // Without the flag, the proxy dials IPv4: a server on ::1 only gives a bad gateway.
        proxy.routes = routes(["six": six.port, "four": four.port])
        let wrong = await tcpExchange(port: port, send: [httpGet("six.localhost")], until: "</html>")
        #expect(wrong.hasPrefix("HTTP/1.1 502 Bad Gateway"))
        let right = await tcpExchange(port: port, send: [httpGet("four.localhost")], until: "four.localhost /")
        #expect(right.contains("four-server four.localhost /"))
    }

    @Test func aListenerOnAllAddressesMakesAPortBusy() async throws {
        let wildcard = try LoopbackListener(.quiet, wildcard: true)
        defer { wildcard.stop() }
        let free = try LoopbackListener.unusedPort()
        let proxy = DomainProxy(addresses: ["127.0.0.1"])
        defer { proxy.stop() }
        #expect(await proxy.start(candidates: [UInt16(wildcard.port)]) == nil)
        #expect(await proxy.start(candidates: [UInt16(wildcard.port), UInt16(free)]) == UInt16(free))
        #expect(await !proxy.isFree(port: UInt16(wildcard.port)))
        #expect(await proxy.isFree(port: UInt16(try LoopbackListener.unusedPort())))
    }

    // MARK: TLS upstream

    @Test func aRouteToATLSPortSplicesToASelfSignedUpstream() async throws {
        let (proxy, port) = try await started()
        defer { proxy.stop() }
        let upstream = try #require(await TLSUpstream.start())
        defer { upstream.stop() }
        proxy.routes = routes(["secure": upstream.port], containerPort: 443)
        let r = await tcpExchange(port: port, send: [httpGet("secure.localhost")], until: "alpn=")
        #expect(r.hasPrefix("HTTP/1.1 200 OK"), "[\(r.prefix(80))]")
        #expect(r.contains("tls-upstream sni=secure.localhost alpn=http/1.1"))
    }

    @Test func aTLSHandshakeThatNeverEndsGetsABadGatewayPage() async throws {
        var limits = DomainProxy.Limits()
        limits.connectTimeout = 1
        let (proxy, port) = try await started(limits: limits)
        defer { proxy.stop() }
        // The upstream accepts the connection and says nothing, so the handshake hangs.
        let silent = try LoopbackListener(.quiet)
        proxy.routes = routes(["secure": silent.port], containerPort: 443)
        let r = await tcpExchange(port: port, send: [httpGet("secure.localhost")], until: "</html>")
        #expect(r.hasPrefix("HTTP/1.1 502 Bad Gateway"))
        #expect(await waitUntil { proxy.sessionCount == 0 })
    }
}
