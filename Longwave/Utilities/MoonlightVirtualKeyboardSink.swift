#if MOONLIGHT_ENABLED
@preconcurrency import MoonlightCommonC

/// Turns our on-screen keyboard's key events into Moonlight virtual-key codes.
///
/// Moonlight is the mirror image of VNC here: it wants the *physical* key plus a
/// modifier bitmask, so a shifted glyph is sent as its unshifted key with the
/// shift bit set — never as a key of its own.
@MainActor
struct MoonlightKeyboardSink: VirtualKeyboardSink {
    /// The session this keyboard types into.
    let library: MoonlightLibrary

    func press(_ key: VirtualKey, modifiers: VirtualModifiers, held: VirtualModifiers) {
        guard let code = Self.virtualKey(for: key) else { return }

        let wrap = modifiers.subtracting(held).ordered
        let mask = Self.mask(modifiers)

        for modifier in wrap {
            library.sendKeyboard(Self.virtualKey(for: modifier), KEY_ACTION_DOWN, modifiers: mask)
        }
        library.sendKeyboard(code, KEY_ACTION_DOWN, modifiers: mask)
        library.sendKeyboard(code, KEY_ACTION_UP, modifiers: mask)
        // Unwind the mask alongside the keys, so the host never sees a release
        // that still claims the modifier is down.
        var remaining = modifiers
        for modifier in wrap.reversed() {
            remaining.remove(modifier)
            library.sendKeyboard(Self.virtualKey(for: modifier), KEY_ACTION_UP, modifiers: Self.mask(remaining))
        }
    }

    func setHeld(_ modifier: VirtualModifiers, held: Bool, allHeld: VirtualModifiers) {
        library.sendKeyboard(Self.virtualKey(for: modifier),
                             held ? KEY_ACTION_DOWN : KEY_ACTION_UP,
                             modifiers: Self.mask(allHeld))
    }

    func insertText(_ text: String) {
        for character in text {
            if character.isNewline {
                press(.return, modifiers: [], held: [])
            } else if let stroke = VirtualKeyboardLayout.stroke(typing: character) {
                press(stroke.key, modifiers: stroke.shift ? .shift : [], held: [])
            }
        }
    }

    /// Ctrl+Alt+Del, which Windows only honours as a genuine key sequence.
    func sendSecureAttention() {
        let ctrl = Self.virtualKey(for: .control)
        let alt = Self.virtualKey(for: .option)
        let del: Int16 = 0x2E
        let both = Int8(MODIFIER_CTRL) | Int8(MODIFIER_ALT)

        library.sendKeyboard(ctrl, KEY_ACTION_DOWN, modifiers: Int8(MODIFIER_CTRL))
        library.sendKeyboard(alt, KEY_ACTION_DOWN, modifiers: both)
        library.sendKeyboard(del, KEY_ACTION_DOWN, modifiers: both)
        library.sendKeyboard(del, KEY_ACTION_UP, modifiers: both)
        library.sendKeyboard(alt, KEY_ACTION_UP, modifiers: Int8(MODIFIER_CTRL))
        library.sendKeyboard(ctrl, KEY_ACTION_UP, modifiers: 0)
    }

    // MARK: - Key Codes

    static func mask(_ modifiers: VirtualModifiers) -> Int8 {
        var mask: Int8 = 0
        if modifiers.contains(.shift) { mask |= Int8(MODIFIER_SHIFT) }
        if modifiers.contains(.control) { mask |= Int8(MODIFIER_CTRL) }
        if modifiers.contains(.option) { mask |= Int8(MODIFIER_ALT) }
        if modifiers.contains(.command) { mask |= Int8(MODIFIER_META) }
        return mask
    }

    private static func virtualKey(for modifier: VirtualModifiers) -> Int16 {
        switch modifier {
        case .control: return 0xA2 // VK_LCONTROL
        case .option: return 0xA4  // VK_LMENU
        case .command: return 0x5B // VK_LWIN
        default: return 0xA0       // VK_LSHIFT
        }
    }

    private static func virtualKey(for key: VirtualKey) -> Int16? {
        switch key {
        case .character(let base, _):
            // Always the unshifted key — the shift bit in the mask does the rest.
            return MoonlightKeyCodes.windowsKeyCode(for: base)
        case .return: return 0x0D
        case .tab: return 0x09
        case .escape: return 0x1B
        case .backspace: return 0x08
        case .forwardDelete: return 0x2E
        case .capsLock: return 0x14
        case .up: return 0x26
        case .down: return 0x28
        case .left: return 0x25
        case .right: return 0x27
        case .home: return 0x24
        case .end: return 0x23
        case .pageUp: return 0x21
        case .pageDown: return 0x22
        case .insert: return 0x2D
        case .function(let number):
            guard (1...12).contains(number) else { return nil }
            return Int16(0x70 + number - 1)
        }
    }
}
#endif
