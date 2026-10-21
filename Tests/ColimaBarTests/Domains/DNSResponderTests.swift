import Darwin
import Foundation
import Testing

@testable import ColimaBar

/// The responder on an ephemeral UDP port of 127.0.0.1. No test binds port 53.
@Suite struct DNSResponderTests {
    private func freePort() throws -> UInt16 {
        for _ in 0..<50 {
            let port = Int.random(in: 30000..<60000)
            if DNSResponder.isFree(port: port) { return UInt16(port) }
        }
        throw POSIXError(.EADDRINUSE)
    }

    private func query(_ name: String, type: UInt16 = 1, id: UInt16 = 7) -> [UInt8] {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { p += [UInt8(label.utf8.count)] + Array(label.utf8) }
        return p + [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
    }

    /// Sends one packet from a new source port and waits up to `wait` seconds.
    private func exchange(_ packet: [UInt8], port: UInt16, wait: Int = 2) async -> [UInt8]? {
        await onOwnThread {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var tv = timeval(tv_sec: wait, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let sent = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == packet.count else { return nil }
            var buffer = [UInt8](repeating: 0, count: 600)
            let n = recv(fd, &buffer, buffer.count, 0)
            return n > 0 ? Array(buffer.prefix(n)) : nil
        }
    }

    private func started(_ responder: DNSResponder, zone: String = "colima.internal") async throws -> UInt16 {
        let port = try freePort()
        responder.zone = zone
        #expect(await responder.start(port: port))
        #expect(responder.port == port)
        return port
    }

    @Test func answersAnAQueryInsideTheZone() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        let q = query("web.shop.colima.internal")
        let a = try #require(await exchange(q, port: port))
        #expect(a == DNSMessage.response(to: q, zone: "colima.internal"))
        #expect(Array(a.suffix(4)) == [127, 0, 0, 1])
    }

    @Test func answersAAAAAndNXDomainOutsideTheZone() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        let aaaa = try #require(await exchange(query("x.colima.internal", type: 28), port: port))
        #expect(Array(aaaa.suffix(16)) == [UInt8](repeating: 0, count: 15) + [1])
        let out = try #require(await exchange(query("example.com"), port: port))
        #expect(out[3] & 0x0F == 3)
    }

    @Test func aMalformedPacketGetsNoAnswerOrFormErr() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        #expect(await exchange([1, 2, 3], port: port, wait: 1) == nil)
        var bad = query("a.colima.internal")
        bad[5] = 2  // QDCOUNT 2
        let reply = try #require(await exchange(bad, port: port))
        #expect(reply[3] & 0x0F == 1)
    }

    @Test func theZoneCanChangeWhileItRuns() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        r.zone = "Dev.TEST."
        #expect(r.zone == "dev.test")
        let a = try #require(await exchange(query("a.dev.test"), port: port))
        #expect(a[3] & 0x0F == 0 && a[7] == 1)
        let old = try #require(await exchange(query("a.colima.internal"), port: port))
        #expect(old[3] & 0x0F == 3)
    }

    @Test func manyQueriesFromManySourcePortsKeepTheFlowsBounded() async throws {
        let r = DNSResponder(unchecked: "127.0.0.1", maxFlows: 8, idleTimeout: 0.3)
        defer { r.stop() }
        let port = try await started(r)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<300 {
                group.addTask { _ = await exchange(query("n\(i).colima.internal"), port: port, wait: 1) }
            }
        }
        #expect(r.flowCount <= 8)
        #expect(await waitUntil { r.flowCount == 0 })
        // It still answers afterwards.
        #expect(await exchange(query("again.colima.internal"), port: port) != nil)
    }

    @Test func stopEndsTheAnswers() async throws {
        let r = DNSResponder()
        let port = try await started(r)
        r.stop()
        #expect(r.port == nil)
        #expect(await exchange(query("a.colima.internal"), port: port, wait: 1) == nil)
    }

    @Test func aBusyPortFailsTheStart() async throws {
        let first = DNSResponder()
        defer { first.stop() }
        let port = try await started(first)
        let second = DNSResponder()
        #expect(await !second.start(port: port))
        #expect(second.port == nil)
        #expect(await !second.start(port: 0))
    }

    @Test func aRestartOnTheSamePortWorks() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        #expect(await r.start(port: port))
        #expect(await exchange(query("a.colima.internal"), port: port) != nil)
    }

    @Test func itBindsLoopbackOnly() {
        #expect(DNSResponder.loopback == "127.0.0.1")
    }

    @Test func theFreePortCheckSeesABoundPort() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        #expect(!DNSResponder.isFree(port: Int(port)))
        #expect(!DNSResponder.isFree(port: 0))
    }
}
