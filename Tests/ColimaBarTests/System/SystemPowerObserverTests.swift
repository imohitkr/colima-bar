import AppKit
import Testing

@testable import ColimaBar

@MainActor
@Suite struct SystemPowerObserverTests {
    private final class Counts {
        var sleeps = 0
        var ends = 0
        var changes = 0
        var last: PowerState?
    }

    private func make() -> (NotificationCenter, SystemPowerObserver, Counts) {
        let center = NotificationCenter()
        let observer = SystemPowerObserver(
            center: center, processCenter: NotificationCenter(), readPower: { PowerState() }, watchesPowerSource: false)
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
        let live = SystemPowerObserver(
            center: center, processCenter: NotificationCenter(), readPower: { PowerState() }, watchesPowerSource: false)
        var marker = 0
        live.onSleepEnd = { marker += 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { marker == 1 })
        #expect(counts.sleeps == 0)
        #expect(counts.ends == 0)
        live.stop()
    }

    // MARK: - Power state

    /// The state that the fake `readPower` returns.
    private final class PowerBox {
        var value = PowerState()
    }

    private func makePower() -> (NotificationCenter, NotificationCenter, PowerBox, SystemPowerObserver, Counts) {
        let center = NotificationCenter()
        let processCenter = NotificationCenter()
        let box = PowerBox()
        let observer = SystemPowerObserver(
            center: center, processCenter: processCenter, readPower: { box.value }, watchesPowerSource: false)
        let counts = Counts()
        observer.onPowerChange = {
            counts.changes += 1
            counts.last = $0
        }
        return (center, processCenter, box, observer, counts)
    }

    @Test func theFirstStateIsReadAtStart() {
        let box = PowerBox()
        box.value = PowerState(onBattery: true)
        let observer = SystemPowerObserver(
            center: NotificationCenter(), processCenter: NotificationCenter(), readPower: { box.value },
            watchesPowerSource: false)
        #expect(observer.power == PowerState(onBattery: true))
        observer.stop()
    }

    @Test func aChangedLowPowerModeCallsOnPowerChange() async {
        let (_, processCenter, box, observer, counts) = makePower()
        box.value = PowerState(lowPowerMode: true)
        processCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(await waitUntil { counts.changes == 1 })
        #expect(observer.power == PowerState(lowPowerMode: true))
        #expect(counts.last == PowerState(lowPowerMode: true))
        observer.stop()
    }

    @Test func aChangedThermalStateCallsOnPowerChange() async {
        let (_, processCenter, box, observer, counts) = makePower()
        box.value = PowerState(isHot: true)
        processCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(await waitUntil { counts.changes == 1 })
        #expect(counts.last == PowerState(isHot: true))
        observer.stop()
    }

    @Test func anUnchangedStateCallsNothing() async {
        let (_, processCenter, box, observer, counts) = makePower()
        processCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        // A later change that does arrive shows that the first post was handled.
        box.value = PowerState(onBattery: true)
        processCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(await waitUntil { counts.changes == 1 })
        #expect(observer.power == PowerState(onBattery: true))
        observer.stop()
    }

    @Test func aWakeReadsThePowerStateAgain() async {
        let (center, _, box, observer, counts) = makePower()
        var ends = 0
        observer.onSleepEnd = { ends += 1 }
        box.value = PowerState(onBattery: true)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { counts.changes == 1 && ends == 1 })
        #expect(counts.last == PowerState(onBattery: true))
        observer.stop()
    }

    @Test func noPowerChangeArrivesAfterStop() async {
        let (center, processCenter, box, observer, counts) = makePower()
        observer.stop()
        box.value = PowerState(lowPowerMode: true)
        processCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        // A later notification that does arrive shows that the earlier ones are gone.
        let live = SystemPowerObserver(
            center: center, processCenter: processCenter, readPower: { PowerState() }, watchesPowerSource: false)
        var marker = 0
        live.onSleepEnd = { marker += 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { marker == 1 })
        #expect(counts.changes == 0)
        live.stop()
    }
}
