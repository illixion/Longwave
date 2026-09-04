import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Maps a hardware key press to the macOS virtual keycode for the same
/// *physical* key position, and platform modifier flags to the wire's
/// `MacNativeKeyModifiers`.
///
/// USB HID keyboard-page usage IDs (`UIKeyboardHIDUsage.rawValue`,
/// `GCKeyCode.rawValue`) are the physical-key identity a real USB keyboard
/// reports regardless of the active input source. macOS virtual keycodes
/// (`kVK_*` from `Carbon.HIToolbox`, `NSEvent.keyCode`) are a different,
/// ADB-derived numbering for the same physical positions. Sending the
/// physical-position keycode (rather than converting to a Unicode character
/// first, the way `VNCKeyCode.withCharacter` does for VNC) lets the Mac's own
/// active keyboard layout resolve the shifted/composed meaning — correct for
/// non-US layouts too, exactly like a real Mac keyboard at that position would
/// behave.
///
/// The tables are keyed by the raw HID usage number so they compile on every
/// client: iOS and visionOS hand the map a `UIKeyboardHIDUsage`, macOS hands it
/// an `NSEvent.keyCode` (already a kVK) and needs the inverse for hosts that
/// negotiated the `hidUsage` key-code space.
enum MacKeyCodeMap {
    /// The HID usages the on-screen keyboard and the modifier logic refer to by
    /// name. Values are the USB HID keyboard/keypad page (0x07) usage IDs.
    enum HID {
        static let returnOrEnter = 40
        static let escape = 41
        static let deleteOrBackspace = 42
        static let tab = 43
        static let spacebar = 44
        static let capsLock = 57
        static let f1 = 58 // F1…F12 are contiguous through 69
        static let insert = 73
        static let home = 74
        static let pageUp = 75
        static let deleteForward = 76
        static let end = 77
        static let pageDown = 78
        static let rightArrow = 79
        static let leftArrow = 80
        static let downArrow = 81
        static let upArrow = 82
        static let leftControl = 224
        static let leftShift = 225
        static let leftAlt = 226
        static let leftGUI = 227
        static let rightControl = 228
        static let rightShift = 229
        static let rightAlt = 230
        static let rightGUI = 231
    }

    /// HID usage → macOS virtual keycode, for every physical key that has one.
    /// Print Screen, Scroll Lock, Pause, the Application/Menu key and F20+ have
    /// no Mac virtual keycode — dropped rather than guessed.
    private static let macKeyCodeByUsage: [Int: UInt16] = [
        // Letters (HID 4…29 = a…z)
        4: 0x00, 5: 0x0B, 6: 0x08, 7: 0x02, 8: 0x0E, 9: 0x03, 10: 0x05, 11: 0x04, 12: 0x22,
        13: 0x26, 14: 0x28, 15: 0x25, 16: 0x2E, 17: 0x2D, 18: 0x1F, 19: 0x23, 20: 0x0C,
        21: 0x0F, 22: 0x01, 23: 0x11, 24: 0x20, 25: 0x09, 26: 0x0D, 27: 0x07, 28: 0x10, 29: 0x06,

        // Digits (HID 30…39 = 1…9, 0)
        30: 0x12, 31: 0x13, 32: 0x14, 33: 0x15, 34: 0x17, 35: 0x16, 36: 0x1A, 37: 0x1C, 38: 0x19, 39: 0x1D,

        // Whitespace / editing
        40: 0x24, // Return
        41: 0x35, // Escape
        42: 0x33, // Delete (backspace)
        43: 0x30, // Tab
        44: 0x31, // Space
        76: 0x75, // Forward Delete

        // Punctuation
        45: 0x1B, // -
        46: 0x18, // =
        47: 0x21, // [
        48: 0x1E, // ]
        49: 0x2A, // backslash
        50: 0x0A, // Non-US # (ISO extra key, kVK_ISO_Section)
        51: 0x29, // ;
        52: 0x27, // '
        53: 0x32, // `
        54: 0x2B, // ,
        55: 0x2F, // .
        56: 0x2C, // /
        57: 0x39, // Caps Lock

        // Function keys (HID 58…69 = F1…F12, 104…110 = F13…F19)
        58: 0x7A, 59: 0x78, 60: 0x63, 61: 0x76, 62: 0x60, 63: 0x61, 64: 0x62, 65: 0x64,
        66: 0x65, 67: 0x6D, 68: 0x67, 69: 0x6F,
        104: 0x69, 105: 0x6B, 106: 0x71, 107: 0x6A, 108: 0x40, 109: 0x4F, 110: 0x50,

        // Navigation
        73: 0x72, // Insert — no Mac Insert key; Help occupies the position
        74: 0x73, // Home
        75: 0x74, // Page Up
        77: 0x77, // End
        78: 0x79, // Page Down
        79: 0x7C, // →
        80: 0x7B, // ←
        81: 0x7D, // ↓
        82: 0x7E, // ↑

        // Keypad
        83: 0x47, // Num Lock — no Mac NumLock; Clear occupies the position
        84: 0x4B, // keypad /
        85: 0x43, // keypad *
        86: 0x4E, // keypad -
        87: 0x45, // keypad +
        88: 0x4C, // keypad Enter
        89: 0x53, 90: 0x54, 91: 0x55, 92: 0x56, 93: 0x57, 94: 0x58, 95: 0x59, 96: 0x5B, 97: 0x5C, // keypad 1…9
        98: 0x52, // keypad 0
        99: 0x41, // keypad .
        103: 0x51, // keypad =

        // Modifiers
        224: 0x3B, // Left Control
        225: 0x38, // Left Shift
        226: 0x3A, // Left Option
        227: 0x37, // Left Command
        228: 0x3E, // Right Control
        229: 0x3C, // Right Shift
        230: 0x3D, // Right Option
        231: 0x36, // Right Command
    ]

    /// macOS virtual keycode → HID usage: the inverse, for the Mac client
    /// talking to a host that negotiated `hidUsage` (Windows). Every kVK above
    /// comes from exactly one usage, so the inversion is lossless.
    private static let usageByMacKeyCode: [UInt16: Int] = {
        var inverse: [UInt16: Int] = [:]
        for (usage, code) in macKeyCodeByUsage where inverse[code] == nil {
            inverse[code] = usage
        }
        return inverse
    }()

    static func keyCode(forHIDUsage usage: Int) -> UInt16? {
        macKeyCodeByUsage[usage]
    }

    static func hidUsage(forMacKeyCode code: UInt16) -> Int? {
        usageByMacKeyCode[code]
    }

    /// The keycode to put on the wire for a physical key, in the server-
    /// negotiated key-code space: the kVK mapping for macOS hosts, the raw HID
    /// usage for hosts that asked for `hidUsage`. The kVK lookup gates which
    /// physical keys are forwarded at all in both cases.
    static func wireKeyCode(forHIDUsage usage: Int, space: MacNativeStreamProtocol.KeyCodeSpace) -> UInt16? {
        guard let macCode = keyCode(forHIDUsage: usage) else { return nil }
        switch space {
        case .macVirtual: return macCode
        case .hidUsage: return UInt16(exactly: usage)
        }
    }

    /// Same, starting from a kVK (the Mac client's `NSEvent.keyCode`).
    static func wireKeyCode(forMacKeyCode code: UInt16, space: MacNativeStreamProtocol.KeyCodeSpace) -> UInt16? {
        switch space {
        case .macVirtual: return usageByMacKeyCode[code] != nil ? code : nil
        case .hidUsage: return hidUsage(forMacKeyCode: code).flatMap { UInt16(exactly: $0) }
        }
    }

    /// The physical key that types `character` on a US ANSI layout.
    ///
    /// Our on-screen keyboard names its caps by the glyph they type
    /// (`VirtualKey.character`), while the wire carries a key *position* — so the
    /// virtual keyboard's sink comes in this way and then goes through
    /// `keyCode(forHIDUsage:)` like a real key press. Only unshifted glyphs are
    /// listed: the layout always reports the base glyph plus a Shift modifier.
    static func hidUsage(typing character: Character) -> Int? {
        characterUsages[character]
    }

    private static let characterUsages: [Character: Int] = [
        "a": 4, "b": 5, "c": 6, "d": 7, "e": 8, "f": 9, "g": 10, "h": 11, "i": 12, "j": 13,
        "k": 14, "l": 15, "m": 16, "n": 17, "o": 18, "p": 19, "q": 20, "r": 21, "s": 22, "t": 23,
        "u": 24, "v": 25, "w": 26, "x": 27, "y": 28, "z": 29,
        "1": 30, "2": 31, "3": 32, "4": 33, "5": 34, "6": 35, "7": 36, "8": 37, "9": 38, "0": 39,
        "-": 45, "=": 46, "[": 47, "]": 48, "\\": 49, ";": 51, "'": 52, "`": 53,
        ",": 54, ".": 55, "/": 56, " ": 44,
    ]

    /// True for a standalone modifier key press (Shift/Control/Option/Command
    /// alone) — these can never be expressed over the text-only fallback
    /// channel (there's no "shortcut" without a paired key), so the capture
    /// views drop them outright when keyboard shortcuts aren't available.
    static func isModifierOnly(hidUsage usage: Int) -> Bool {
        switch usage {
        case HID.leftControl, HID.rightControl, HID.leftShift, HID.rightShift,
             HID.leftAlt, HID.rightAlt, HID.leftGUI, HID.rightGUI, HID.capsLock:
            return true
        default:
            return false
        }
    }

    // MARK: - UIKit (iOS, visionOS)

    #if canImport(UIKit)
    static func keyCode(for hid: UIKeyboardHIDUsage) -> UInt16? {
        keyCode(forHIDUsage: Int(hid.rawValue))
    }

    static func isModifierOnly(_ hid: UIKeyboardHIDUsage) -> Bool {
        isModifierOnly(hidUsage: Int(hid.rawValue))
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
    #endif
}
