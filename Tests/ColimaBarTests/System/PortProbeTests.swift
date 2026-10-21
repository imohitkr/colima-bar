import Darwin
import Foundation
import Testing

@testable import ColimaBar

@Suite struct PortProbeTests {
    /// A long wait for the peek: a peer that closes makes the socket readable at once,
    /// so the result does not depend on the time.
    private func probe(_ port: Int, peekWait: TimeInterval = 10) async -> PortProbe.Result {
        await PortProbe.check(port: port, connectTimeout: 5, peekWait: peekWait)
    }

    @Test func aServerThatAcceptsAndStaysQuietIsOpen() async throws {
        let listener = try LoopbackListener(.quiet)
        defer { listener.stop() }
        #expect(await probe(listener.port, peekWait: 0.1) == .open)
    }

    @Test func aServerThatSendsBytesIsOpen() async throws {
        let listener = try LoopbackListener(.greets)
        defer { listener.stop() }
        #expect(await probe(listener.port) == .open)
    }

    @Test func aServerThatAcceptsAndClosesAtOnceIsClosed() async throws {
        let listener = try LoopbackListener(.closesAtOnce)
        defer { listener.stop() }
        #expect(await probe(listener.port) == .closed)
    }

    @Test func aPortWithNoServerIsRefused() async throws {
        #expect(await probe(try LoopbackListener.unusedPort()) == .refused)
    }

    @Test func listensIsTrueForAnyServerOnTheLoopback() async throws {
        let quiet = try LoopbackListener(.quiet)
        defer { quiet.stop() }
        #expect(await PortProbe.listens(port: quiet.port, ipv6: false, timeout: 2))
        let dead = try LoopbackListener(.closesAtOnce)
        defer { dead.stop() }
        #expect(await PortProbe.listens(port: dead.port, ipv6: false, timeout: 2))
    }

    @Test func listensIsFalseWhenNothingListens() async throws {
        let port = try LoopbackListener.unusedPort()
        #expect(!(await PortProbe.listens(port: port, ipv6: false, timeout: 2)))
        #expect(!(await PortProbe.listens(port: port, ipv6: true, timeout: 2)))
    }

    @Test func listensLooksAtTheOtherFamilyOnly() async throws {
        // The listener is on 127.0.0.1, so ::1 does not answer.
        let quiet = try LoopbackListener(.quiet)
        defer { quiet.stop() }
        #expect(!(await PortProbe.listens(port: quiet.port, ipv6: true, timeout: 2)))
    }

    @Test func aPortOutOfRangeIsRefused() async {
        #expect(await probe(0) == .refused)
        #expect(await probe(70000) == .refused)
    }

    @Test func aProbeSendsNoData() async throws {
        let listener = try LoopbackListener(.quiet)
        defer { listener.stop() }
        _ = await probe(listener.port, peekWait: 0.1)
        #expect(await waitUntil { listener.acceptedCount == 1 })
        #expect(listener.receivedBytes == 0)
    }

    @Test func manyPortsGetOneResultEach() async throws {
        let open = try LoopbackListener(.greets)
        let dead = try LoopbackListener(.closesAtOnce)
        defer {
            open.stop()
            dead.stop()
        }
        let unused = try LoopbackListener.unusedPort()
        let result = await PortProbe.check(ports: [open.port, dead.port, unused], peekWait: 10)
        #expect(result == [open.port: .open, dead.port: .closed, unused: .refused])
    }

    @Test func onlyARefusedConnectMeansThatNothingListens() {
        #expect(PortProbe.connectFailure(ECONNREFUSED) == .refused)
        #expect(PortProbe.connectFailure(ETIMEDOUT) == .timeout)
        #expect(PortProbe.connectFailure(EHOSTUNREACH) == .timeout)
    }

    @Test func aLocalFailureOfAConnectIsAnErrorNotARefusal() {
        #expect(PortProbe.connectFailure(EMFILE) == .error)
        #expect(PortProbe.connectFailure(ENOBUFS) == .error)
        #expect(PortProbe.connectFailure(EACCES) == .error)
    }
}
