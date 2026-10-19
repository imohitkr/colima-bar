import Carbon.HIToolbox

/// The name of a key in the current keyboard layout, so a German keyboard
/// shows Y where a US keyboard shows Z. TIS needs the main thread.
@MainActor
enum KeyLayout {
    /// The uppercase character for `keyCode`, or nil if the layout gives
    /// none or a control character.
    static func name(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).uppercased()
        guard let scalar = text.unicodeScalars.first, scalar.value > 0x20, scalar.value != 0x7F else { return nil }
        return text
    }
}
