import Foundation
import Testing

@testable import ColimaBar

@Suite struct BusyMarkerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    @Test func readsTheLabelAndThePID() {
        #expect(BusyMarker.parse("Starting work\n4242\n") == .init(label: "Starting work", pid: 4242))
        #expect(BusyMarker.parse("Restarting\n") == .init(label: "Restarting", pid: nil))
        #expect(BusyMarker.parse("") == .init(label: "Working", pid: nil))
        #expect(BusyMarker.parse("Stopping\nabc\n").pid == nil)
        #expect(BusyMarker.parse("Stopping\n0\n").pid == nil)
    }

    @Test func aMarkerWithoutAPIDIsStaleAfter20Minutes() {
        #expect(!BusyMarker.isStale(mtime: ago(19 * 60), now: now, pid: nil, ownerStarted: nil))
        #expect(BusyMarker.isStale(mtime: ago(21 * 60), now: now, pid: nil, ownerStarted: nil))
    }

    @Test func aMarkerWhoseOwnerRunsIsNeverStaleByAge() {
        // The Mac slept for hours: the owner started before the marker.
        #expect(!BusyMarker.isStale(mtime: ago(5 * 3600), now: now, pid: 7, ownerStarted: ago(5 * 3600 + 5)))
    }

    @Test func aMarkerWhoseOwnerIsGoneIsStaleAtOnce() {
        #expect(BusyMarker.isStale(mtime: ago(5), now: now, pid: 7, ownerStarted: nil))
    }

    @Test func aMarkerWhosePIDWasReusedIsStale() {
        #expect(BusyMarker.isStale(mtime: ago(3600), now: now, pid: 7, ownerStarted: ago(600)))
        // The file time and the start time round to about a second.
        #expect(!BusyMarker.isStale(mtime: ago(3600), now: now, pid: 7, ownerStarted: ago(3599)))
    }
}
