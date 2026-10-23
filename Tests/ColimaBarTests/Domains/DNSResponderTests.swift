import Darwin
import Foundation
import Testing

@testable import ColimaBar

/// The responder on an ephemeral UDP port of 127.0.0.1. No test binds port 53.
@Suite struct DNSResponderTests {
    private func query(_ name: String, type: UInt16 = 1, id: UInt16 = 7) -> [UInt8] {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { p += [UInt8(label.utf8.count)] + Array(label.utf8) }
        return p + [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
    }

    /// Sends `packets` back to back from ONE new source port to `host`, and
    /// reads replies until `count` came or `wait` seconds passed without one.
    private func exchangeMany(
        _ packets: [[UInt8]], port: UInt16, host: String = "127.0.0.1", count: Int? = nil, wait: Int = 30
    ) async -> [[UInt8]] {
        await onOwnThread {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var tv = timeval(tv_sec: wait, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(host)
            for packet in packets {
                let sent = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard sent == packet.count else { return [] }
            }
            var replies: [[UInt8]] = []
            var buffer = [UInt8](repeating: 0, count: 600)
            while replies.count < (count ?? packets.count) {
                let n = recv(fd, &buffer, buffer.count, 0)
                guard n > 0 else { break }
                replies.append(Array(buffer.prefix(n)))
            }
            return replies
        }
    }

    /// Sends one packet from a new source port and waits up to `wait` seconds.
    private func exchange(_ packet: [UInt8], port: UInt16, wait: Int = 30) async -> [UInt8]? {
        await exchangeMany([packet], port: port, wait: wait).first
    }

    /// Binds a free port (port 0, so no test races for a number) and returns it.
    private func started(_ responder: DNSResponder, zone: String = "colima.internal") async throws -> UInt16 {
        responder.zone = zone
        #expect(await responder.start(port: 0))
        return try #require(responder.port)
    }

    /// An IPv4 address of this Mac that is not loopback, or nil.
    private func nonLoopbackAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            let flags = Int32(current.pointee.ifa_flags)
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
                {
                    return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            node = current.pointee.ifa_next
        }
        return nil
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

    @Test func answersAAndAAAAThatCameBackToBackFromOneSocket() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        // getaddrinfo sends both from one socket at once. Repeat, to catch a race.
        for round in 0..<10 {
            let a = query("web.shop.colima.internal", type: 1, id: 0x100 + UInt16(round))
            let aaaa = query("web.shop.colima.internal", type: 28, id: 0x200 + UInt16(round))
            let replies = await exchangeMany([a, aaaa], port: port)
            #expect(replies.count == 2, "round \(round)")
            let byID = Dictionary(grouping: replies, by: { UInt16($0[0]) << 8 | UInt16($0[1]) })
            #expect(byID[0x100 + UInt16(round)]?.first.map { Array($0.suffix(4)) } == [127, 0, 0, 1])
            #expect(
                byID[0x200 + UInt16(round)]?.first.map { Array($0.suffix(16)) }
                    == [UInt8](repeating: 0, count: 15) + [1])
        }
    }

    @Test func oneSocketGetsAnswersForManyMessagesAndTheFlowEndsWhenIdle() async throws {
        let r = DNSResponder(unchecked: "127.0.0.1", idleTimeout: 0.3)
        defer { r.stop() }
        let port = try await started(r)
        let packets = (0..<20).map { query("n\($0).colima.internal", id: UInt16(1000 + $0)) }
        #expect(await exchangeMany(packets, port: port).count == 20)
        #expect(await waitUntil { r.flowCount == 0 })
    }

    @Test func theLastMessageOfAFlowGetsItsAnswerAndThenTheFlowCloses() async throws {
        let r = DNSResponder(unchecked: "127.0.0.1", idleTimeout: 30)
        defer { r.stop() }
        let port = try await started(r)
        let packets = (0..<r.maxMessagesPerFlow).map { query("n\($0).colima.internal", id: UInt16(2000 + $0)) }
        #expect(await exchangeMany(packets, port: port).count == r.maxMessagesPerFlow)
        // The close follows the send, not the idle timer.
        #expect(await waitUntil { r.flowCount == 0 })
    }

    @Test func aBadPacketDoesNotEndTheFlow() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        let replies = await exchangeMany([[1, 2, 3], query("a.colima.internal"), []], port: port, count: 1)
        #expect(replies.count == 1 && replies[0][3] & 0x0F == 0)
    }

    @Test func answersAAAAAndRefusesOutsideTheZone() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        let aaaa = try #require(await exchange(query("x.colima.internal", type: 28), port: port))
        #expect(Array(aaaa.suffix(16)) == [UInt8](repeating: 0, count: 15) + [1])
        let out = try #require(await exchange(query("example.com"), port: port))
        #expect(out[3] & 0x0F == 5 && out[2] & 0x04 == 0)
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
        #expect(old[3] & 0x0F == 5)
    }

    @Test func manyQueriesFromManySourcePortsKeepTheFlowsBounded() async throws {
        let r = DNSResponder(unchecked: "127.0.0.1", maxFlows: 8, idleTimeout: 0.3)
        defer { r.stop() }
        let port = try await started(r)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
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
    }

    @Test func aRestartOnTheSamePortWorks() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        #expect(await r.start(port: port))
        // UDP can drop the first query while the new listener settles; a resolver asks again too.
        var reply: [UInt8]?
        for _ in 0..<3 where reply == nil {
            reply = await exchange(query("a.colima.internal"), port: port)
        }
        #expect(reply != nil)
    }

    @Test func itBindsLoopbackOnly() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        // Control: the loopback address answers.
        #expect(await exchange(query("a.colima.internal"), port: port) != nil)
        // Another address of this Mac gets no answer: nothing listens there.
        guard let other = nonLoopbackAddress() else { return }
        let replies = await exchangeMany([query("a.colima.internal")], port: port, host: other, wait: 1)
        #expect(replies.isEmpty, "the responder answered on \(other)")
    }

    @Test func theFreePortCheckSeesABoundPort() async throws {
        let r = DNSResponder()
        defer { r.stop() }
        let port = try await started(r)
        #expect(!DNSResponder.isFree(port: Int(port)))
        #expect(!DNSResponder.isFree(port: 0))
    }
}
