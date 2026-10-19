import AppKit
import Testing

@testable import ColimaBar

@Suite struct KeyComboTests {
    private let allMods: UInt32 = KeyCombo.control | KeyCombo.option | KeyCombo.shift | KeyCombo.command
    private let ctrlOptCmdC = KeyCombo(keyCode: 8, modifiers: 0x1900)

    // MARK: - Spec

    @Test func everySupportedKeyRoundTripsThroughItsSpec() throws {
        for code in KeyCombo.supportedKeyCodes {
            let combo = KeyCombo(keyCode: code, modifiers: KeyCombo.control | KeyCombo.command)
            let back = try #require(KeyCombo(spec: combo.spec), "\(code)")
            #expect(back == combo)
        }
    }

    @Test func everyModifierSetRoundTripsThroughItsSpec() throws {
        let bits = [KeyCombo.control, KeyCombo.option, KeyCombo.shift, KeyCombo.command]
        for subset in 0..<16 {
            var mask: UInt32 = 0
            for (i, bit) in bits.enumerated() where subset & (1 << i) != 0 { mask |= bit }
            let combo = KeyCombo(keyCode: 8, modifiers: mask)
            #expect(KeyCombo(spec: combo.spec) == combo)
        }
    }

    @Test func theSpecHasACanonicalForm() {
        #expect(ctrlOptCmdC.spec == "control+option+command+C")
        #expect(KeyCombo(keyCode: 8, modifiers: allMods).spec == "control+option+shift+command+C")
        #expect(KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command).spec == "option+command+space")
        #expect(KeyCombo(keyCode: 96, modifiers: KeyCombo.control).spec == "control+F5")
    }

    @Test func theSpecIgnoresCaseAndOrder() {
        #expect(KeyCombo(spec: "COMMAND+Option+control+c") == ctrlOptCmdC)
        #expect(KeyCombo(spec: "command+option+control+c")?.spec == "control+option+command+C")
    }

    @Test func rejectsABadSpec() {
        #expect(KeyCombo(spec: "") == nil)
        #expect(KeyCombo(spec: "control+option") == nil)
        #expect(KeyCombo(spec: "control+A+B") == nil)
        #expect(KeyCombo(spec: "control+banana") == nil)
        #expect(KeyCombo(spec: "control+control+C") == nil)
        #expect(KeyCombo(spec: "control++C") == nil)
        #expect(KeyCombo(spec: "control+keypad1") == nil)
        #expect(KeyCombo(spec: "+") == nil)
    }

    // MARK: - Flags

    @Test func eventFlagsMapToTheCarbonMask() {
        let combo = KeyCombo(keyCode: 8, flags: [.control, .option, .command])
        #expect(combo == ctrlOptCmdC)
        #expect(combo.modifiers == 0x1900)
        #expect(KeyCombo(keyCode: 8, flags: [.shift]).modifiers == KeyCombo.shift)
    }

    @Test func capsLockFunctionAndKeypadFlagsAreDropped() {
        let combo = KeyCombo(keyCode: 8, flags: [.control, .option, .command, .capsLock, .function, .numericPad])
        #expect(combo == ctrlOptCmdC)
    }

    // MARK: - Rules

    @Test func twoModifiersAreEnough() {
        #expect(ctrlOptCmdC.problem == nil)
        #expect(KeyCombo(keyCode: 8, modifiers: KeyCombo.control | KeyCombo.option).problem == nil)
        #expect(KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command).problem == nil)
    }

    @Test func oneModifierIsNotEnoughForALetter() {
        #expect(KeyCombo(keyCode: 8, modifiers: KeyCombo.command).problem == .tooFewModifiers(functionKey: false))
        #expect(KeyCombo(keyCode: 8, modifiers: 0).problem == .tooFewModifiers(functionKey: false))
    }

    @Test func shiftDoesNotCount() {
        let shifted = KeyCombo(keyCode: 8, modifiers: KeyCombo.command | KeyCombo.shift)
        #expect(shifted.problem == .tooFewModifiers(functionKey: false))
    }

    @Test func aFunctionKeyNeedsOneModifier() {
        #expect(KeyCombo(keyCode: 96, modifiers: KeyCombo.command).problem == nil)
        #expect(KeyCombo(keyCode: 96, modifiers: 0).problem == .tooFewModifiers(functionKey: true))
        #expect(KeyCombo(keyCode: 96, modifiers: KeyCombo.shift).problem == .tooFewModifiers(functionKey: true))
    }

    @Test func anUnknownKeyIsUnsupported() {
        #expect(KeyCombo(keyCode: 82, modifiers: 0x1900).problem == .unsupportedKey)  // keypad 0
    }

    @Test func everyProblemHasAMessage() {
        let problems: [KeyCombo.Problem] = [
            .unsupportedKey, .tooFewModifiers(functionKey: true), .tooFewModifiers(functionKey: false), .system,
            .inUse, .failed(-50),
        ]
        for p in problems { #expect(!p.message.isEmpty) }
        #expect(KeyCombo.Problem.failed(-50).message.contains("error -50"))
    }

    // MARK: - Text

    @Test func symbolsFollowTheOrderControlOptionShiftCommand() {
        #expect(ctrlOptCmdC.symbols(keyName: nil) == "⌃⌥⌘C")
        #expect(KeyCombo(keyCode: 8, modifiers: allMods).symbols(keyName: nil) == "⌃⌥⇧⌘C")
    }

    @Test func theLayoutNameReplacesTheUSKeyName() {
        let combo = KeyCombo(keyCode: 6, modifiers: 0x1900)  // the Z position
        #expect(combo.symbols(keyName: nil) == "⌃⌥⌘Z")
        #expect(combo.symbols(keyName: "y") == "⌃⌥⌘Y")
    }

    @Test func namedKeysIgnoreTheLayoutName() {
        let combo = KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command)
        #expect(combo.symbols(keyName: "x") == "⌥⌘Space")
        #expect(KeyCombo(keyCode: 123, modifiers: 0x1900).symbols(keyName: nil) == "⌃⌥⌘←")
        #expect(KeyCombo(keyCode: 96, modifiers: KeyCombo.control).symbols(keyName: nil) == "⌃F5")
    }

    @Test func spokenTextUsesWords() {
        #expect(ctrlOptCmdC.spoken == "Control Option Command C")
        #expect(KeyCombo(keyCode: 116, modifiers: 0x1900).spoken == "Control Option Command Page Up")
        #expect(KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command).spoken == "Option Command Space")
    }

    // MARK: - System shortcuts

    private func entry(code: Int, mods: Int, enabled: Int = 1) -> [String: Any] {
        [
            "kHISymbolicHotKeyCode": code, "kHISymbolicHotKeyModifiers": mods,
            "kHISymbolicHotKeyEnabled": enabled,
        ]
    }

    @Test func anEnabledSystemShortcutIsReserved() {
        let combo = KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command)
        #expect(combo.isReserved(in: [entry(code: 49, mods: 0x900)]))
    }

    @Test func aDisabledSystemShortcutIsNotReserved() {
        let combo = KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command)
        #expect(!combo.isReserved(in: [entry(code: 49, mods: 0x900, enabled: 0)]))
    }

    @Test func otherKeysAndModifiersAreNotReserved() {
        let combo = KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command)
        #expect(!combo.isReserved(in: [entry(code: 50, mods: 0x900), entry(code: 49, mods: 0x1100)]))
        #expect(!combo.isReserved(in: []))
        #expect(!combo.isReserved(in: [["kHISymbolicHotKeyCode": 49]]))
    }

    @Test func theReservedCheckLooksOnlyAtTheModifierMask() {
        let combo = KeyCombo(keyCode: 49, modifiers: KeyCombo.option | KeyCombo.command)
        #expect(combo.isReserved(in: [entry(code: 49, mods: 0x900 | 0x20000)]))
    }
}
