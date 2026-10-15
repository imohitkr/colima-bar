import Foundation
import Testing

@testable import ColimaBar

@Suite struct ProcessProbeTests {
    @Test func theTestProcessRuns() throws {
        let started = try #require(ProcessProbe.startTime(pid: Int(getpid())))
        #expect(started < Date().addingTimeInterval(1))
        #expect(ProcessProbe.isAlive(pid: Int(getpid())))
    }

    @Test func aPIDWithNoProcessIsNotAlive() {
        #expect(ProcessProbe.startTime(pid: 99_999_999) == nil)
        #expect(!ProcessProbe.isAlive(pid: 99_999_999))
        #expect(ProcessProbe.startTime(pid: 0) == nil)
        #expect(ProcessProbe.startTime(pid: -5) == nil)
    }
}
