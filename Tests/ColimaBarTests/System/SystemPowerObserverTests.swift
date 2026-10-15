import AppKit
import Testing

@testable import ColimaBar

@MainActor
@Suite struct SystemPowerObserverTests {
    private final class Counts {
        var sleeps = 0
        var ends = 0
    }

    private func make() -> (NotificationCenter, SystemPowerObserver, Counts) {
        let center = NotificationCenter()
        let observer = SystemPowerObserver(center: center)
        let counts = Counts()
        observer.onSleep = { counts.sleeps += 1 }
        observer.onSleepEnd = { counts.ends += 1 }
        return (center, observer, counts)
    }

    @Test func sleepAndAfterSleepCallTheirCallbacks() async {
        let (center, observer, counts) = make()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await waitUntil { counts.sleeps == 1 })
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { counts.ends == 1 })
        #expect(counts.sleeps == 1)
        observer.stop()
    }

    @Test func nothingArrivesAfterStop() async {
        let (center, observer, counts) = make()
        observer.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        // A later notification that does arrive shows that the earlier ones are gone.
        let live = SystemPowerObserver(center: center)
        var marker = 0
        live.onSleepEnd = { marker += 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { marker == 1 })
        #expect(counts.sleeps == 0)
        #expect(counts.ends == 0)
        live.stop()
    }
}
