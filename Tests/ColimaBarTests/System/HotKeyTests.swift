import Carbon.HIToolbox
import Testing

@testable import ColimaBar

@Suite struct HotKeyTests {
    @Test func successHasNoProblem() {
        #expect(HotKey.problem(for: noErr) == nil)
    }

    @Test func aKeyThatAnotherAppHoldsIsInUse() {
        #expect(HotKey.problem(for: OSStatus(eventHotKeyExistsErr)) == .inUse)
        #expect(OSStatus(eventHotKeyExistsErr) == -9878)
    }

    @Test func anyOtherStatusIsAFailure() {
        #expect(HotKey.problem(for: -50) == .failed(-50))
        #expect(HotKey.problem(for: OSStatus(eventHotKeyInvalidErr)) == .failed(OSStatus(eventHotKeyInvalidErr)))
    }

    @Test func theMessagesTellWhatToDo() {
        #expect(HotKey.problem(for: -9878)?.message == "Another app uses this shortcut. Record a different one.")
        #expect(
            HotKey.problem(for: -50)?.message == "macOS refused this shortcut (error -50). Record a different one.")
    }

    @Test func theSignatureSpellsCBar() {
        #expect(HotKey.signature == 0x4342_6172)
    }
}

@MainActor @Suite struct HotKeyRegistrationTests {
    private let spec = "control+option+command+C"
    private let other = KeyCombo(spec: "control+option+command+D")!

    @Test func startRegistersTheStoredShortcut() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        #expect(hotKey.combo?.spec == spec)
        #expect(hotKey.isActive)
        #expect(hotKey.problem == nil)
        #expect(fake.registerCalls.count == 1)
    }

    @Test func aDebugRunReadsTheShortcutButNeverRegistersIt() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: true)
        #expect(hotKey.combo?.spec == spec)
        #expect(!hotKey.isActive)
        #expect(fake.installCalls == 0)
        #expect(fake.registerCalls.isEmpty)
    }

    @Test func aStoredValueThatDoesNotParseIsNotRegistered() {
        let fake = FakeHotKeyBackend(stored: "control+option+nonsense")
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        #expect(hotKey.combo == nil)
        #expect(!hotKey.isActive)
        #expect(fake.registerCalls.isEmpty)
        #expect(fake.stored == "control+option+nonsense")
    }

    @Test func aStoredShortcutWithTooFewModifiersIsNeverRegistered() {
        let fake = FakeHotKeyBackend(stored: "command+C")
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        #expect(hotKey.combo?.spec == "command+C")
        #expect(hotKey.problem == .tooFewModifiers(functionKey: false))
        #expect(!hotKey.isActive)
        #expect(fake.registerCalls.isEmpty)
    }

    @Test func aStoredShortcutThatMacOSUsesIsNeverRegistered() {
        let fake = FakeHotKeyBackend(stored: spec)
        fake.symbolic = [
            [
                "kHISymbolicHotKeyEnabled": 1, "kHISymbolicHotKeyCode": 8,
                "kHISymbolicHotKeyModifiers": 0x1900,
            ]
        ]
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        #expect(hotKey.problem == .system)
        #expect(fake.registerCalls.isEmpty)
    }

    @Test func aHandlerThatDoesNotInstallStopsTheRegistration() {
        let fake = FakeHotKeyBackend(stored: spec)
        fake.installStatus = -50
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        #expect(hotKey.problem == .failed(-50))
        #expect(!hotKey.isActive)
        #expect(fake.registerCalls.isEmpty)
        #expect(hotKey.set(other) == .failed(-50))
        #expect(fake.registerCalls.isEmpty)
        #expect(fake.stored == spec)
    }

    @Test func aRefusedNewShortcutKeepsTheOldOneRegistered() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        fake.registerStatuses = [OSStatus(eventHotKeyExistsErr)]
        #expect(hotKey.set(other) == .inUse)
        #expect(hotKey.combo?.spec == spec)
        #expect(hotKey.problem == nil)
        #expect(hotKey.isActive)
        #expect(fake.stored == spec)
    }

    @Test func aRefusedNewShortcutShowsWhyTheOldOneDoesNotWork() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        fake.registerStatuses = [OSStatus(eventHotKeyExistsErr), OSStatus(eventHotKeyExistsErr)]
        #expect(hotKey.set(other) == .inUse)
        #expect(hotKey.combo?.spec == spec)
        #expect(hotKey.problem == .inUse)
        #expect(!hotKey.isActive)
    }

    @Test func aRefusedNewShortcutDoesNotRegisterTheOldOneWhilePaused() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        hotKey.pause()
        fake.registerStatuses = [OSStatus(eventHotKeyExistsErr)]
        #expect(hotKey.set(other) == .inUse)
        #expect(!hotKey.isActive)
        #expect(fake.registerCalls.count == 2)
        hotKey.resume()
        #expect(hotKey.isActive)
    }

    @Test func aNewShortcutIsSavedAfterItRegisters() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        #expect(hotKey.set(other) == nil)
        #expect(hotKey.combo == other)
        #expect(fake.stored == other.spec)
        #expect(hotKey.set(nil) == nil)
        #expect(hotKey.combo == nil)
        #expect(!hotKey.isActive)
        #expect(fake.stored == nil)
    }

    @Test func withNoShortcutStartInstallsAndWritesNothing() {
        let fake = FakeHotKeyBackend()
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        hotKey.stop()
        #expect(hotKey.combo == nil)
        #expect(!hotKey.isActive)
        #expect(fake.installCalls == 0)
        #expect(fake.removeCalls == 0)
        #expect(fake.unregisterCalls == 0)
        #expect(fake.stored == nil)
    }

    @Test func stopRemovesTheHandlerOnce() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        hotKey.stop()
        hotKey.stop()
        #expect(fake.removeCalls == 1)
        #expect(fake.unregisterCalls == 1)
        #expect(!hotKey.isActive)
    }

    @Test func aNewShortcutThatBreaksARuleChangesNothing() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        let weak = KeyCombo(spec: "command+C")!
        #expect(hotKey.set(weak) == .tooFewModifiers(functionKey: false))
        #expect(fake.registerCalls.count == 1)
        #expect(hotKey.isActive)
        #expect(fake.stored == spec)
    }

    @Test func aNewShortcutThatMacOSUsesChangesNothing() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        fake.symbolic = [
            [
                "kHISymbolicHotKeyEnabled": 1, "kHISymbolicHotKeyCode": 2,
                "kHISymbolicHotKeyModifiers": 0x1900,
            ]
        ]
        #expect(hotKey.set(other) == .system)
        #expect(fake.registerCalls.count == 1)
        #expect(hotKey.combo?.spec == spec)
        #expect(hotKey.isActive)
    }

    @Test func pauseAndResumeStayBalancedAfterASuccessfulChange() {
        let fake = FakeHotKeyBackend(stored: spec)
        let hotKey = fake.hotKey()
        hotKey.start(debug: false)
        hotKey.pause()
        #expect(!hotKey.isActive)
        #expect(hotKey.set(other) == nil)
        hotKey.resume()
        #expect(hotKey.isActive)
        #expect(fake.registerCalls.map(\.spec) == [spec, other.spec])
    }
}
