import AppKit
import Testing

@testable import ColimaBar

@Suite struct ShortcutRecordingTests {
    private typealias R = ShortcutRecording

    @Test func escapeCancels() {
        #expect(R.step(keyCode: 53, flags: [], isRepeat: false) == .cancel)
    }

    @Test func escapeCancelsWithModifiers() {
        #expect(R.step(keyCode: 53, flags: [.command, .option], isRepeat: false) == .cancel)
        #expect(R.step(keyCode: 53, flags: [.control], isRepeat: true) == .cancel)
    }

    @Test func aRepeatedKeyIsIgnored() {
        #expect(R.step(keyCode: 8, flags: [.control, .option, .command], isRepeat: true) == .ignore)
    }

    @Test func aKeyWithModifiersGivesACombo() {
        let step = R.step(keyCode: 8, flags: [.control, .option, .command], isRepeat: false)
        guard case .combo(let combo) = step else {
            Issue.record("expected a combo")
            return
        }
        #expect(combo.keyCode == 8)
        #expect(combo.modifiers == 0x1900)
    }

    @Test func aKeyWithoutModifiersStillGivesAComboForTheMessage() {
        #expect(R.step(keyCode: 0, flags: [], isRepeat: false) == .combo(KeyCombo(keyCode: 0, modifiers: 0)))
    }

    @Test func heldModifiersShowInTheOrderControlOptionShiftCommand() {
        #expect(R.symbols(for: [.command, .shift, .option, .control]) == "⌃⌥⇧⌘")
        #expect(R.symbols(for: [.capsLock]) == "")
    }
}
