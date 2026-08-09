#if os(visionOS)
import UIKit

/// Maps a hardware key press to the macOS virtual keycode for the same
/// *physical* key position, and `UIKeyModifierFlags` to the wire's
/// `MacNativeKeyModifiers`.
///
/// `UIKeyboardHIDUsage` raw values are USB HID keyboard-page usage IDs — the
/// same physical-key identity a real USB keyboard reports regardless of the
/// active input source. macOS virtual keycodes (`kVK_*` from
/// `Carbon.HIToolbox`) are a different, ADB-derived numbering for the same
/// physical positions. Sending the physical-position keycode (rather than
/// converting to a Unicode character first, the way `VNCKeyCode.withCharacter`
/// does for VNC) lets the Mac's own active keyboard layout resolve the
/// shifted/composed meaning — correct for non-US layouts too, exactly like a
/// real Mac keyboard at that position would behave.
enum MacKeyCodeMap {
    static func keyCode(for hid: UIKeyboardHIDUsage) -> UInt16? {
        switch hid {
        // Letters
        case .keyboardA: return 0x00
        case .keyboardB: return 0x0B
        case .keyboardC: return 0x08
        case .keyboardD: return 0x02
        case .keyboardE: return 0x0E
        case .keyboardF: return 0x03
        case .keyboardG: return 0x05
        case .keyboardH: return 0x04
        case .keyboardI: return 0x22
        case .keyboardJ: return 0x26
        case .keyboardK: return 0x28
        case .keyboardL: return 0x25
        case .keyboardM: return 0x2E
        case .keyboardN: return 0x2D
        case .keyboardO: return 0x1F
        case .keyboardP: return 0x23
        case .keyboardQ: return 0x0C
        case .keyboardR: return 0x0F
        case .keyboardS: return 0x01
        case .keyboardT: return 0x11
        case .keyboardU: return 0x20
        case .keyboardV: return 0x09
        case .keyboardW: return 0x0D
        case .keyboardX: return 0x07
        case .keyboardY: return 0x10
        case .keyboardZ: return 0x06

        // Digits
        case .keyboard1: return 0x12
        case .keyboard2: return 0x13
        case .keyboard3: return 0x14
        case .keyboard4: return 0x15
        case .keyboard5: return 0x17
        case .keyboard6: return 0x16
        case .keyboard7: return 0x1A
        case .keyboard8: return 0x1C
        case .keyboard9: return 0x19
        case .keyboard0: return 0x1D

        // Whitespace / editing
        case .keyboardReturnOrEnter: return 0x24
        case .keyboardEscape: return 0x35
        case .keyboardDeleteOrBackspace: return 0x33
        case .keyboardTab: return 0x30
        case .keyboardSpacebar: return 0x31
        case .keyboardDeleteForward: return 0x75

        // Punctuation
        case .keyboardHyphen: return 0x1B
        case .keyboardEqualSign: return 0x18
        case .keyboardOpenBracket: return 0x21
        case .keyboardCloseBracket: return 0x1E
        case .keyboardBackslash: return 0x2A
        case .keyboardNonUSPound: return 0x0A // ISO extra key (kVK_ISO_Section)
        case .keyboardSemicolon: return 0x29
        case .keyboardQuote: return 0x27
        case .keyboardGraveAccentAndTilde: return 0x32
        case .keyboardComma: return 0x2B
        case .keyboardPeriod: return 0x2F
        case .keyboardSlash: return 0x2C
        case .keyboardCapsLock: return 0x39

        // Function keys
        case .keyboardF1: return 0x7A
        case .keyboardF2: return 0x78
        case .keyboardF3: return 0x63
        case .keyboardF4: return 0x76
        case .keyboardF5: return 0x60
        case .keyboardF6: return 0x61
        case .keyboardF7: return 0x62
        case .keyboardF8: return 0x64
        case .keyboardF9: return 0x65
        case .keyboardF10: return 0x6D
        case .keyboardF11: return 0x67
        case .keyboardF12: return 0x6F
        case .keyboardF13: return 0x69
        case .keyboardF14: return 0x6B
        case .keyboardF15: return 0x71
        case .keyboardF16: return 0x6A
        case .keyboardF17: return 0x40
        case .keyboardF18: return 0x4F
        case .keyboardF19: return 0x50

        // Navigation
        case .keyboardInsert: return 0x72 // no Mac Insert key; Help occupies the position
        case .keyboardHome: return 0x73
        case .keyboardPageUp: return 0x74
        case .keyboardEnd: return 0x77
        case .keyboardPageDown: return 0x79
        case .keyboardRightArrow: return 0x7C
        case .keyboardLeftArrow: return 0x7B
        case .keyboardDownArrow: return 0x7D
        case .keyboardUpArrow: return 0x7E

        // Keypad
        case .keypadNumLock: return 0x47 // no Mac NumLock; Clear occupies the position
        case .keypadSlash: return 0x4B
        case .keypadAsterisk: return 0x43
        case .keypadHyphen: return 0x4E
        case .keypadPlus: return 0x45
        case .keypadEnter: return 0x4C
        case .keypad1: return 0x53
        case .keypad2: return 0x54
        case .keypad3: return 0x55
        case .keypad4: return 0x56
        case .keypad5: return 0x57
        case .keypad6: return 0x58
        case .keypad7: return 0x59
        case .keypad8: return 0x5B
        case .keypad9: return 0x5C
        case .keypad0: return 0x52
        case .keypadPeriod: return 0x41
        case .keypadEqualSign: return 0x51

        // Modifiers
        case .keyboardLeftControl: return 0x3B
        case .keyboardLeftShift: return 0x38
        case .keyboardLeftAlt: return 0x3A
        case .keyboardLeftGUI: return 0x37
        case .keyboardRightControl: return 0x3E
        case .keyboardRightShift: return 0x3C
        case .keyboardRightAlt: return 0x3D
        case .keyboardRightGUI: return 0x36

        default:
            // Print Screen, Scroll Lock, Pause, the Application/Menu key, and
            // F20+ have no Mac virtual keycode — dropped rather than guessed.
            return nil
        }
    }

    /// True for a standalone modifier key press (Shift/Control/Option/Command
    /// alone) — these can never be expressed over the text-only fallback
    /// channel (there's no "shortcut" without a paired key), so the capture
    /// view drops them outright when keyboard shortcuts aren't available.
    static func isModifierOnly(_ hid: UIKeyboardHIDUsage) -> Bool {
        switch hid {
        case .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI,
             .keyboardCapsLock:
            return true
        default:
            return false
        }
    }

    static func modifiers(for flags: UIKeyModifierFlags) -> MacNativeKeyModifiers {
        var result: MacNativeKeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alphaShift) { result.insert(.capsLock) }
        return result
    }
}
#endif
